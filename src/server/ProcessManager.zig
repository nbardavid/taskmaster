const std = @import("std");
const log = std.log;
const mem = std.mem;
const heap = std.heap;
const Thread = std.Thread;
const posix = std.posix;

const AutoArrayHashMapUnmanaged = std.AutoArrayHashMapUnmanaged;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const HashMap = std.StringArrayHashMapUnmanaged;

const common = @import("common");
const Config = common.Config;
const Process = @import("Process.zig");
const ExitCode = Process.ExitCode;

pub const ProcessManager = @This();

gpa: mem.Allocator,
config: Config,
live: HashMap(*Process),
live_pid: AutoArrayHashMapUnmanaged(posix.pid_t, ProcessChild),
thread: ?Thread,
stopping: std.atomic.Value(bool) = .{ .raw = false },
new_cmd: std.atomic.Value(bool) = .{ .raw = false },
cmd: common.Command,
cmd_payload: [256]u8,

pub const ProcessChild = struct {
    parent: *Process,
    index: usize,
};

pub fn init(gpa: mem.Allocator, config_file_path: []const u8) ProcessManager {
    return .{
        .gpa = gpa,
        .config = Config.init(config_file_path),
        .live = HashMap(*Process).empty,
        .live_pid = AutoArrayHashMapUnmanaged(posix.pid_t, ProcessChild).empty,
        .thread = null,
        .stopping = .{ .raw = false },
        .new_cmd = .{ .raw = false },
        .cmd = undefined,
        .cmd_payload = undefined,
    };
}

fn checkForNewCommand(self: *ProcessManager, out_cmd: *common.Command, out_cmd_payload: *[256]u8) bool {
    if (self.new_cmd.load(.acquire)) {
        out_cmd.* = self.cmd;
        const payload_len = self.cmd.payload_len;
        @memcpy(out_cmd_payload[0..payload_len], self.cmd_payload[0..payload_len]);
        self.new_cmd.store(false, .monotonic);
        return true;
    }
    return false;
}

fn loadConfig(self: *ProcessManager) !Config.ParsedResult {
    try self.config.open();
    return try self.config.parseLeaky(self.gpa);
}

fn stageNewConfig(self: *ProcessManager, parsed: *Config.ParsedResult) !HashMap(*Process) {
    var result_map = parsed.getResultMap();
    const total_processes: usize = result_map.map.count();

    var list: ArrayListUnmanaged(*Process) = .empty;
    defer list.deinit(self.gpa);
    errdefer {
        for (list.items) |process| process.destroy(self.gpa);
    }
    try list.ensureUnusedCapacity(self.gpa, total_processes);

    for (0..total_processes) |_| {
        const proc = try Process.create(self.gpa);
        list.appendAssumeCapacity(proc);
    }

    var it = result_map.map.iterator();
    var i: usize = 0;
    while (it.next()) |entry| : (i += 1) {
        try list.items[i].configure(entry.key_ptr.*, entry.value_ptr);
    }

    var new_staged: HashMap(*Process) = .empty;
    errdefer new_staged.deinit(self.gpa);

    try new_staged.ensureUnusedCapacity(self.gpa, total_processes);
    for (list.items) |process| {
        new_staged.putAssumeCapacity(process.config.name, process);
    }

    return new_staged;
}

fn cleanupStagedConfig(self: *ProcessManager, staged: *HashMap(*Process)) void {
    var it = staged.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.*.destroy(self.gpa);
    }
    staged.deinit(self.gpa);
    staged.* = HashMap(*Process).empty;
}

fn commitStagedConfig(self: *ProcessManager, staged: *HashMap(*Process)) !HashMap(*Process) {
    var new_live: HashMap(*Process) = .empty;
    errdefer new_live.deinit(self.gpa);
    try new_live.ensureUnusedCapacity(self.gpa, staged.count());

    var it = staged.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const staged_proc = entry.value_ptr.*;

        if (self.live.get(name)) |old_proc| {
            const staged_hash = staged_proc.hash();
            const old_hash = old_proc.hash();

            if (staged_hash == old_hash) {
                try new_live.put(self.gpa, name, old_proc);
            } else {
                try self.stopProcess(old_proc);
                try new_live.put(self.gpa, name, staged_proc);
                if (staged_proc.config.conf.autostart)
                    try self.startProcess(staged_proc);
            }
        } else {
            try new_live.put(self.gpa, name, staged_proc);
            if (staged_proc.config.conf.autostart)
                try self.startProcess(staged_proc);
        }
    }

    var it_old = self.live.iterator();
    while (it_old.next()) |entry| {
        const name = entry.key_ptr.*;
        const old_proc = entry.value_ptr.*;
        if (!new_live.contains(name)) {
            try self.stopProcess(old_proc);
            old_proc.destroy(self.gpa);
        }
    }

    var it_staged = staged.iterator();
    while (it_staged.next()) |entry| {
        const name = entry.key_ptr.*;
        const staged_proc = entry.value_ptr.*;
        if (!new_live.contains(name)) {
            staged_proc.destroy(self.gpa);
        }
    }

    self.live.deinit(self.gpa);
    staged.deinit(self.gpa);
    return new_live;
}

fn replaceProcess(self: *ProcessManager, old_proc: *Process, new_proc: *Process) !void {
    try self.stopProcess(old_proc);
    old_proc.destroy(self.gpa);

    if (new_proc.config.conf.autostart) {
        try self.startProcess(new_proc);
    }
}

fn stopProcess(self: *ProcessManager, proc: *Process) !void {
    for (proc.instances) |*inst| {
        if (inst.pid) |pid| {
            try inst.stop(@intFromEnum(proc.config.conf.stopsignal), proc.config.conf.stoptime * 1000);
            _ = self.live_pid.swapRemove(pid);
        }
    }
}

fn startProcess(self: *ProcessManager, proc: *Process) !void {
    const arena = proc.arena.allocator();
    for (proc.instances, 0..) |*inst, i| {
        try inst.start(&proc.config, arena);
        if (inst.pid) |pid| {
            try self.live_pid.put(self.gpa, pid, .{ .parent = proc, .index = i });
        }
    }
}

fn restartProcess(self: *ProcessManager, proc: *Process) !void {
    try self.stopProcess(proc);
    try self.startProcess(proc);
}

fn manageProcess(self: *ProcessManager, proc: *Process) !void {
    const now: u64 = @intCast(std.time.milliTimestamp());

    for (proc.instances, 0..) |*child, i| {
        switch (child.status) {
            .starting => {
                if ((now - child.last_start_time) >= (proc.config.conf.starttime * 1000)) {
                    child.status = .running;
                }
            },
            .exited => {
                const should_restart = switch (proc.config.conf.autorestart) {
                    .always => true,
                    .unexpected => if (child.exit_code) |code| !proc.isExpectedExitCode(code) else true,
                    .never => false,
                };

                if (should_restart and child.retries < proc.config.conf.startretries) {
                    child.retries += 1;
                    try child.start(&proc.config, proc.arena.allocator());
                    if (child.pid) |pid| {
                        try self.live_pid.put(self.gpa, pid, .{ .parent = proc, .index = i });
                    }
                } else if (!should_restart) {
                    child.status = .stopped;
                } else {
                    child.status = .fatal;
                }
            },
            else => {},
        }
    }
}

fn applyLiveConfig(self: *ProcessManager) !void {
    var it = self.live.iterator();
    while (it.next()) |entry| {
        try self.manageProcess(entry.value_ptr.*);
    }
}

fn mainLoop(self: *ProcessManager) !void {
    var fatal_error: anyerror = undefined;
    var current_parsed_result: Config.ParsedResult = .empty;
    defer current_parsed_result.deinit();
    var new_config_staging: HashMap(*Process) = .empty;
    errdefer self.cleanupStagedConfig(&new_config_staging);
    var local_command: common.Command = undefined;
    var local_command_payload: [256]u8 = undefined;

    state: switch (Status.pm_needs_to_load_initial_config) {
        .pm_needs_to_load_initial_config => {
            log.info("state=LOAD_INITIAL_CONFIG", .{});
            if (self.stopping.load(.acquire)) continue :state .pm_shutdown;

            if (self.loadConfig()) |result| {
                log.info("config loaded successfully", .{});
                current_parsed_result = result;
                current_parsed_result.valid = true;
                continue :state .pm_needs_to_stage_new_config;
            } else |err| {
                log.err("config load failed: {}", .{err});
                fatal_error = err;
                continue :state .pm_failed_to_load_config;
            }
        },
        .pm_needs_to_stage_new_config => {
            log.info("state=STAGE_NEW_CONFIG", .{});
            if (self.stopping.load(.acquire)) continue :state .pm_shutdown;

            if (self.stageNewConfig(&current_parsed_result)) |new_config| {
                log.info("staged new config successfully ({} processes)", .{new_config.count()});
                new_config_staging = new_config;
                continue :state .pm_needs_to_commit_new_config;
            } else |err| {
                log.err("staging config failed: {}", .{err});
                fatal_error = err;
                continue :state .pm_failed_to_stage_config;
            }
        },
        .pm_needs_to_commit_new_config => {
            log.info("state=COMMIT_NEW_CONFIG", .{});
            if (self.stopping.load(.acquire)) continue :state .pm_shutdown;

            if (self.commitStagedConfig(&new_config_staging)) |new_live| {
                log.info("committed new config ({} live processes)", .{new_live.count()});
                self.live = new_live;
                continue :state .pm_needs_to_apply_new_config;
            } else |err| {
                log.err("commit config failed: {}", .{err});
                fatal_error = err;
                continue :state .pm_failed_to_commit_config;
            }
        },
        .pm_needs_to_apply_new_config => {
            log.debug("state=APPLY_NEW_CONFIG", .{});
            if (self.stopping.load(.acquire)) continue :state .pm_shutdown;

            if (self.applyLiveConfig()) {
                log.debug("applied live config successfully", .{});
                continue :state .pm_needs_to_wait_for_commands;
            } else |err| {
                log.err("apply config failed: {}", .{err});
                fatal_error = err;
                continue :state .pm_failed_to_apply_config;
            }
        },
        .pm_needs_to_wait_for_commands => {
            if (self.stopping.load(.acquire)) continue :state .pm_shutdown;
            if (self.checkForNewCommand(&local_command, &local_command_payload)) {
                continue :state .pm_needs_to_exec_command;
            } else {
                Thread.sleep(std.time.ns_per_ms);
                continue :state .pm_needs_to_wait_for_commands;
            }
        },
        .pm_needs_to_exec_command => {
            switch (local_command.cmd) {
                .dump => {
                    log.info("dump\n", .{});
                },
                .quit => {
                    log.info("quit\n", .{});
                },
                .reload => {
                    log.info("reload\n", .{});
                },
                .restart => {
                    log.info("restart\n", .{});
                },
                .start => {
                    log.info("start\n", .{});
                },
                .status => {
                    log.info("status\n", .{});
                },
                .stop => {
                    log.info("stop\n", .{});
                },
            }
            continue :state .pm_needs_to_wait_for_commands;
        },
        .pm_failed_to_load_config => {
            log.err("failed to load config: {}", .{fatal_error});
            continue :state .pm_encountered_fatal_error;
        },
        .pm_failed_to_stage_config => {
            log.err("failed to stage config: {}", .{fatal_error});
            continue :state .pm_encountered_fatal_error;
        },
        .pm_failed_to_commit_config => {
            log.err("failed to commit config: {}", .{fatal_error});
            continue :state .pm_encountered_fatal_error;
        },
        .pm_failed_to_apply_config => {
            log.err("failed to apply config: {}", .{fatal_error});
            continue :state .pm_encountered_fatal_error;
        },
        .pm_encountered_fatal_error => {
            log.err("fatal error in process manager: {}", .{fatal_error});
            return fatal_error;
        },
        .pm_shutdown => {
            log.info("process manager loop shutting down", .{});
            return;
        },
    }
}

pub fn start(self: *ProcessManager) !void {
    const thread = try Thread.spawn(.{}, ProcessManager.mainLoop, .{self});
    self.thread = thread;
}

const Status = enum {
    pm_shutdown,
    pm_needs_to_load_initial_config,
    pm_needs_to_stage_new_config,
    pm_needs_to_commit_new_config,
    pm_needs_to_apply_new_config,
    pm_needs_to_wait_for_commands,
    pm_needs_to_exec_command,
    pm_failed_to_load_config,
    pm_failed_to_stage_config,
    pm_failed_to_commit_config,
    pm_failed_to_apply_config,
    pm_encountered_fatal_error,
};

fn shutdown(self: *ProcessManager) !void {
    var it = self.live.iterator();
    while (it.next()) |entry| {
        try self.stopProcess(entry.value_ptr.*);
    }
}

pub fn deinit(self: *ProcessManager) void {
    self.stopping.store(true, .release);

    if (self.thread) |t| {
        t.join();
        self.thread = null;
    }

    self.shutdown() catch {};
    self.config.deinit();

    var it = self.live.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.*.destroy(self.gpa);
    }

    self.live.deinit(self.gpa);
    self.live_pid.deinit(self.gpa);
}
