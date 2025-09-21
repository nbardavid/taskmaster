const ProcessManager = @This();

gpa: mem.Allocator,
config: Config,
process_mpool: heap.MemoryPool(Process),
live: HashMap(*Process),
live_pid: AutoArrayHashMapUnmanaged(posix.pid_t, ProcessChild),
thread: Thread,

const ProcessChild = struct {
    parent: *Process,
    index: usize,
};

pub fn init(gpa: mem.Allocator, config_file_path: []const u8) ProcessManager {
    return .{
        .gpa = gpa,
        .config = Config.init(config_file_path),
        .process_mpool = heap.MemoryPool(Process).init(gpa),
        .live = HashMap(*Process).empty,
        .live_pid = AutoArrayHashMapUnmanaged(posix.pid_t, ProcessChild).empty,
        .thread = undefined,
    };
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
        for (list.items) |process| {
            process.deinit();
            self.process_mpool.destroy(process);
        }
    }
    try list.ensureUnusedCapacity(self.gpa, total_processes);

    for (0..total_processes) |_| {
        const process: *Process = try self.process_mpool.create();
        process.* = .init(self.gpa);
        list.appendAssumeCapacity(process);
    }

    var it = result_map.map.iterator();
    var i: usize = 0;
    while (it.next()) |entry| : (i += 1) {
        try list.items[i].configure(entry.key_ptr.*, entry.value_ptr);
    }

    var new_staged_config: HashMap(*Process) = .empty;
    errdefer new_staged_config.deinit(self.gpa);

    try new_staged_config.ensureUnusedCapacity(self.gpa, total_processes);
    for (list.items) |process| {
        new_staged_config.putAssumeCapacity(process.config.name, process);
    }

    return new_staged_config;
}

fn cleanupStagedConfig(self: *ProcessManager, staged: *HashMap(*Process)) void {
    var it = staged.iterator();
    while (it.next()) |entry| {
        const process_who_hasnt_been_used_or_started = entry.value_ptr.*;
        process_who_hasnt_been_used_or_started.deinit();
        self.process_mpool.destroy(process_who_hasnt_been_used_or_started);
    }
    staged.deinit(self.gpa);
}

fn commitStagedConfig(self: *ProcessManager, staged: *HashMap(*Process)) !HashMap(*Process) {
    var new_live: HashMap(*Process) = .empty;
    errdefer new_live.deinit(self.gpa);
    try new_live.ensureUnusedCapacity(self.gpa, staged.count());

    var it = staged.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const new_proc = entry.value_ptr.*;
        if (self.live.get(name)) |old_proc| {
            if (new_proc.hash() == old_proc.hash()) {
                new_proc.deinit();
                self.process_mpool.destroy(new_proc);
                try new_live.put(self.gpa, name, old_proc);
            } else {
                try self.stopProcess(old_proc);
                old_proc.deinit();
                self.process_mpool.destroy(old_proc);

                try new_live.put(self.gpa, name, new_proc);
                if (new_proc.config.conf.autostart)
                    try self.startProcess(new_proc);
            }
        } else {
            try new_live.put(self.gpa, name, new_proc);
            if (new_proc.config.conf.autostart)
                try self.startProcess(new_proc);
        }
    }

    var it_old = self.live.iterator();
    while (it_old.next()) |entry| {
        const name = entry.key_ptr.*;
        const old_proc = entry.value_ptr.*;
        if (!new_live.contains(name)) {
            try self.stopProcess(old_proc);
            old_proc.deinit();
            self.process_mpool.destroy(old_proc);
        }
    }

    self.live.deinit(self.gpa);
    staged.deinit(self.gpa);
    return new_live;
}

fn replaceProcess(self: *ProcessManager, old_proc: *Process, new_proc: *Process) !void {
    try self.stopProcess(old_proc);
    old_proc.deinit();
    self.process_mpool.destroy(old_proc);

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

pub fn start(self: *ProcessManager) !void {
    var fatal_error: anyerror = undefined;
    var current_parsed_result: Config.ParsedResult = undefined;
    var new_config_staging: HashMap(*Process) = .empty;
    errdefer self.cleanupStagedConfig(&new_config_staging);

    state: switch (Status.pm_needs_to_load_initial_config) {
        .pm_needs_to_load_initial_config => {
            if (self.loadConfig()) |result| {
                current_parsed_result = result;
                continue :state .pm_needs_to_stage_new_config;
            } else |err| {
                fatal_error = err;
                continue :state .pm_failed_to_load_config;
            }
        },
        .pm_needs_to_stage_new_config => {
            if (self.stageNewConfig(&current_parsed_result)) |new_config| {
                new_config_staging = new_config;
                continue :state .pm_needs_to_commit_new_config;
            } else |err| {
                fatal_error = err;
                continue :state .pm_failed_to_stage_config;
            }
        },
        .pm_needs_to_commit_new_config => {
            if (self.commitStagedConfig(&new_config_staging)) |new_live| {
                self.live = new_live;
                continue :state .pm_needs_to_apply_new_config;
            } else |err| {
                fatal_error = err;
                continue :state .pm_failed_to_commit_config;
            }
        },
        .pm_needs_to_apply_new_config => {
            if (self.applyLiveConfig()) {
                //
            } else |err| {
                fatal_error = err;
                continue :state .pm_failed_to_apply_config;
            }
        },
        .pm_failed_to_load_config => {
            log.err("failed to load config : {}", .{fatal_error});
            continue :state .pm_encountered_fatal_error;
        },
        .pm_failed_to_stage_config => {
            log.err("failed to stage config : {}", .{fatal_error});
            continue :state .pm_encountered_fatal_error;
        },
        .pm_failed_to_commit_config => {
            log.err("failed to commit config : {}", .{fatal_error});
            continue :state .pm_encountered_fatal_error;
        },
        .pm_failed_to_apply_config => {
            log.err("failed to apply config : {}", .{fatal_error});
            continue :state .pm_encountered_fatal_error;
        },

        .pm_encountered_fatal_error => {
            log.err("failed to load config : {}", .{fatal_error});
            return fatal_error;
        },
    }
}

const Status = enum {
    pm_needs_to_load_initial_config,
    pm_needs_to_stage_new_config,
    pm_needs_to_commit_new_config,
    pm_needs_to_apply_new_config,
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
    self.shutdown() catch {};
    self.process_mpool.deinit();
    self.config.deinit();
    self.live.deinit(self.gpa);
    self.thread.join();
}

const std = @import("std");
const log = std.log;
const heap = std.heap;
const mem = std.mem;
const Io = std.Io;
const Thread = std.Thread;
const posix = std.posix;

const AutoArrayHashMapUnmanaged = std.AutoArrayHashMapUnmanaged;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const HashMap = std.StringArrayHashMapUnmanaged;
const common = @import("common");
const Config = common.Config;
const Process = @import("Process.zig");
const ExitCode = Process.ExitCode;
