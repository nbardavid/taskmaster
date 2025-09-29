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
const Child = @import("Child.zig");

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

pub fn start(self: *ProcessManager) !void {
    const thread = try Thread.spawn(.{}, ProcessManager.mainLoop, .{self});
    self.thread = thread;
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
                staged_proc.destroy(self.gpa);
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
            self.removeLivePid(pid);
        }
    }
}

fn startProcess(self: *ProcessManager, proc: *Process) !void {
    const arena = proc.arena.allocator();
    for (proc.instances, 0..) |*inst, i| {
        try inst.start(&proc.config, arena);
        try self.updateLivePid(inst, proc, i);
    }
}

fn restartProcess(self: *ProcessManager, proc: *Process) !void {
    try self.stopProcess(proc);
    try self.startProcess(proc);
}

fn updateLivePid(self: *ProcessManager, child: *const Child, proc: *Process, index: usize) !void {
    if (child.pid) |pid| {
        // Add or update PID tracking
        try self.live_pid.put(self.gpa, pid, .{ .parent = proc, .index = index });
    }
}

fn removeLivePid(self: *ProcessManager, pid: posix.pid_t) void {
    _ = self.live_pid.swapRemove(pid);
}

fn manageProcess(self: *ProcessManager, proc: *Process) !void {
    const now: u64 = @intCast(std.time.milliTimestamp());

    for (proc.instances, 0..) |*child, i| {
        // Always poll for child process status changes first
        if (child.pid) |pid| {
            if (try child.poll()) |_| {
                // Child process has exited, remove from live_pid tracking
                self.removeLivePid(pid);
            }
        }

        switch (child.status) {
            .starting => {
                if ((now - child.last_start_time) >= (proc.config.conf.starttime * 1000)) {
                    child.status = .running;
                }
                // Note: .starting -> .exited transition is handled by polling above
            },
            .backoff => {
                // Handle backoff expiration
                if (child.backoff_until) |until| {
                    if (now >= until) {
                        // Backoff expired, decide next action based on restart policy
                        const should_restart = switch (proc.config.conf.autorestart) {
                            .always => true,
                            .unexpected => if (child.exit_code) |code| !proc.isExpectedExitCode(code) else true,
                            .never => false,
                        };

                        if (should_restart and child.retries < proc.config.conf.startretries) {
                            // Try restarting again
                            child.backoff_until = null;
                            try child.restart(&proc.config, proc.arena.allocator());
                            try self.updateLivePid(child, proc, i);
                        } else {
                            // No more restarts, mark as stopped or fatal
                            child.status = if (should_restart) .fatal else .stopped;
                            child.backoff_until = null;
                        }
                    }
                }
            },
            .exited => {
                const should_restart = switch (proc.config.conf.autorestart) {
                    .always => true,
                    .unexpected => if (child.exit_code) |code| !proc.isExpectedExitCode(code) else true,
                    .never => false,
                };

                if (should_restart and child.retries < proc.config.conf.startretries) {
                    // Use consistent restart logic through child.restart()
                    try child.restart(&proc.config, proc.arena.allocator());
                    try self.updateLivePid(child, proc, i);
                } else if (!should_restart) {
                    child.status = .stopped;
                } else {
                    child.status = .fatal;
                }
            },
            .running => {
                // Running state is stable, nothing to do here
                // Transitions out of .running are handled by polling (-> .exited)
                // or by external commands (-> .stopping)
            },
            .stopping => {
                // Stopping state should transition to .exited when process actually exits
                // This is handled by polling above, but we can add a timeout check
                // if the process doesn't respond to signals within reasonable time
            },
            .stopped => {
                // Stopped is a terminal state unless manually restarted
            },
            .fatal => {
                // Fatal is a terminal state
            },
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

    state: switch (Status.process_manager_needs_to_load_the_inial_config) {
        .process_manager_needs_to_load_the_inial_config => {
            log.info("state=LOAD_INITIAL_CONFIG", .{});
            if (self.stopping.load(.acquire)) continue :state .process_manager_needs_to_shutdown;

            if (self.loadConfig()) |result| {
                log.info("config loaded successfully", .{});
                current_parsed_result = result;
                current_parsed_result.valid = true;
                continue :state .process_manager_needs_to_stage_the_new_config;
            } else |err| {
                log.err("config load failed: {}", .{err});
                fatal_error = err;
                continue :state .process_manager_failed_to_load_config;
            }
        },

        .process_manager_needs_to_load_a_config => {
            log.info("state=LOAD_CONFIG", .{});
            if (self.stopping.load(.acquire)) continue :state .process_manager_needs_to_shutdown;

            current_parsed_result.deinit();
            current_parsed_result = .empty;
            current_parsed_result.valid = false;

            if (self.config.parseLeaky(self.gpa)) |result| {
                log.info("config loaded successfully", .{});
                current_parsed_result = result;
                current_parsed_result.valid = true;
                continue :state .process_manager_needs_to_stage_the_new_config;
            } else |err| {
                log.err("config load failed: {}", .{err});
                fatal_error = err;
                continue :state .process_manager_failed_to_load_config;
            }
        },

        .process_manager_needs_to_stage_the_new_config => {
            log.info("state=STAGE_NEW_CONFIG", .{});
            if (self.stopping.load(.acquire)) continue :state .process_manager_needs_to_shutdown;

            if (self.stageNewConfig(&current_parsed_result)) |new_config| {
                log.info("staged new config successfully ({} processes)", .{new_config.count()});
                new_config_staging = new_config;
                continue :state .process_manager_needs_to_commit_the_new_config;
            } else |err| {
                log.err("staging config failed: {}", .{err});
                fatal_error = err;
                continue :state .process_manager_failed_to_stage_config;
            }
        },

        .process_manager_needs_to_commit_the_new_config => {
            log.info("state=COMMIT_NEW_CONFIG", .{});
            if (self.stopping.load(.acquire)) continue :state .process_manager_needs_to_shutdown;

            if (self.commitStagedConfig(&new_config_staging)) |new_live| {
                log.info("committed new config ({} live processes)", .{new_live.count()});
                self.live = new_live;
                continue :state .process_manager_needs_to_apply_the_new_config;
            } else |err| {
                log.err("commit config failed: {}", .{err});
                fatal_error = err;
                continue :state .process_manager_failed_to_commit_config;
            }
        },

        .process_manager_needs_to_apply_the_new_config => {
            log.debug("state=APPLY_NEW_CONFIG", .{});
            if (self.stopping.load(.acquire)) continue :state .process_manager_needs_to_shutdown;

            if (self.applyLiveConfig()) {
                log.debug("applied live config successfully", .{});
                continue :state .process_manager_needs_to_check_for_new_command;
            } else |err| {
                log.err("apply config failed: {}", .{err});
                fatal_error = err;
                continue :state .process_manager_failed_to_apply_config;
            }
        },

        .process_manager_needs_to_check_for_new_command => {
            if (self.stopping.load(.acquire)) continue :state .process_manager_needs_to_shutdown;
            if (self.checkForNewCommand(&local_command, &local_command_payload)) {
                log.info("state=PM_NEEDS_TO_WAIT_FOR_COMMANDS ", .{});
                continue :state .process_manager_needs_to_route_the_new_command;
            } else {
                Thread.sleep(std.time.ns_per_ms);
                continue :state .process_manager_needs_to_check_for_new_command;
            }
        },

        .process_manager_needs_to_route_the_new_command => {
            log.info("state=PM_NEEDS_TO_EXEC_COMMAND", .{});
            switch (local_command.cmd) {
                .status => continue :state .process_manager_exec_status,
                .start => continue :state .process_manager_exec_start,
                .stop => continue :state .process_manager_exec_stop,
                .restart => continue :state .process_manager_exec_restart,
                .reload => continue :state .process_manager_exec_reload,
                .dump => continue :state .process_manager_exec_dump,
                .quit => continue :state .process_manager_exec_quit,
            }
            continue :state .process_manager_needs_to_check_for_new_command;
        },

        .process_manager_exec_status => {
            var it = self.live.iterator();
            while (it.next()) |entry| {
                const proc = entry.value_ptr.*;
                self.printProcessStatus(proc);
            }
            continue :state .process_manager_needs_to_check_for_new_command;
        },

        .process_manager_exec_start => {
            const name = local_command_payload[0..local_command.payload_len];
            if (self.live.get(name)) |proc| {
                if (self.startProcess(proc)) |_| {
                    log.info("started {s}", .{name});
                } else |err| {
                    log.err("failed to start {s}: {}", .{ name, err });
                    fatal_error = err;
                    continue :state .process_manager_encountered_fatal_error;
                }
            } else {
                log.warn("no process named {s}", .{name});
            }
            continue :state .process_manager_needs_to_check_for_new_command;
        },

        .process_manager_exec_stop => {
            const name = local_command_payload[0..local_command.payload_len];
            if (self.live.get(name)) |proc| {
                if (self.stopProcess(proc)) |_| {
                    log.info("stopped {s}", .{name});
                } else |err| {
                    log.err("failed to stop {s}: {}", .{ name, err });
                    fatal_error = err;
                    continue :state .process_manager_encountered_fatal_error;
                }
            } else {
                log.warn("no process named {s}", .{name});
            }
            continue :state .process_manager_needs_to_check_for_new_command;
        },

        .process_manager_exec_restart => {
            const name = local_command_payload[0..local_command.payload_len];
            if (self.live.get(name)) |proc| {
                if (self.restartProcess(proc)) |_| {
                    log.info("restarted {s}", .{name});
                } else |err| {
                    log.err("failed to restart {s}: {}", .{ name, err });
                    fatal_error = err;
                    continue :state .process_manager_encountered_fatal_error;
                }
            } else {
                log.warn("no process named {s}", .{name});
            }
            continue :state .process_manager_needs_to_check_for_new_command;
        },

        .process_manager_exec_reload => {
            log.info("reloading config…", .{});
            continue :state .process_manager_reset_config_file_seek_position;
        },

        .process_manager_reset_config_file_seek_position => {
            log.info("reloading content of config file", .{});
            if (self.config.reload()) {
                continue :state .process_manager_needs_to_load_a_config;
            } else |err| {
                log.err("failed to reload config {}", .{err});
                fatal_error = err;
                continue :state .process_manager_encountered_fatal_error;
            }
        },

        .process_manager_exec_dump => {
            var it = self.live.iterator();
            while (it.next()) |entry| {
                const proc = entry.value_ptr.*;
                self.printProcessStatus(proc);
            }
            continue :state .process_manager_needs_to_check_for_new_command;
        },

        .process_manager_exec_quit => {
            log.info("received quit", .{});
            self.stopping.store(true, .release);
            continue :state .process_manager_needs_to_shutdown;
        },

        .process_manager_failed_to_load_config => {
            log.err("failed to load config: {}", .{fatal_error});
            continue :state .process_manager_encountered_fatal_error;
        },

        .process_manager_failed_to_stage_config => {
            log.err("failed to stage config: {}", .{fatal_error});
            continue :state .process_manager_encountered_fatal_error;
        },

        .process_manager_failed_to_commit_config => {
            log.err("failed to commit config: {}", .{fatal_error});
            continue :state .process_manager_encountered_fatal_error;
        },

        .process_manager_failed_to_apply_config => {
            log.err("failed to apply config: {}", .{fatal_error});
            continue :state .process_manager_encountered_fatal_error;
        },

        .process_manager_encountered_fatal_error => {
            log.err("fatal error in process manager: {}", .{fatal_error});
            return fatal_error;
        },

        .process_manager_needs_to_shutdown => {
            log.info("process manager loop shutting down", .{});
            return;
        },
    }
}

const Status = enum {
    process_manager_encountered_fatal_error,
    process_manager_exec_dump,
    process_manager_exec_quit,
    process_manager_exec_reload,
    process_manager_exec_restart,
    process_manager_exec_start,
    process_manager_exec_status,
    process_manager_exec_stop,
    process_manager_failed_to_apply_config,
    process_manager_failed_to_commit_config,
    process_manager_failed_to_load_config,
    process_manager_failed_to_stage_config,
    process_manager_needs_to_apply_the_new_config,
    process_manager_needs_to_check_for_new_command,
    process_manager_needs_to_commit_the_new_config,
    process_manager_needs_to_load_a_config,
    process_manager_needs_to_load_the_inial_config,
    process_manager_needs_to_route_the_new_command,
    process_manager_needs_to_shutdown,
    process_manager_needs_to_stage_the_new_config,
    process_manager_reset_config_file_seek_position,
};

fn shutdown(self: *ProcessManager) !void {
    var it = self.live.iterator();
    while (it.next()) |entry| {
        try self.stopProcess(entry.value_ptr.*);
    }
}

fn printProcessStatus(self: *ProcessManager, proc: *Process) void {
    _ = self;
    const status = proc.currentStatus();
    const status_symbol = switch (status) {
        .running => "●",
        .stopped, .exited => "○",
        .fatal => "✗",
        .backoff => "◐",
        else => "◯",
    };

    const status_color = switch (status) {
        .running => "\x1b[32m", // green
        .stopped, .exited => "\x1b[37m", // white
        .fatal => "\x1b[31m", // red
        .backoff => "\x1b[33m", // yellow
        else => "\x1b[37m", // white
    };

    const reset_color = "\x1b[0m";

    // Process name and command line
    log.info("{s}{s}{s} {s} - {s}", .{ status_color, status_symbol, reset_color, proc.config.name, proc.config.conf.cmd });

    // Loaded line
    log.info("     Loaded: loaded (command: {s}, numprocs: {d})", .{ proc.config.conf.cmd, proc.config.conf.numprocs });

    // Active line with status details
    const status_str = switch (status) {
        .running => "active (running)",
        .stopped => "inactive (dead)",
        .exited => "inactive (exited)",
        .fatal => "failed (fatal)",
        .backoff => "activating (backoff)",
        else => "unknown",
    };

    log.info("     Active: {s}{s}{s}", .{ status_color, status_str, reset_color });

    // Instance information
    var running_count: usize = 0;
    var main_pid: ?std.posix.pid_t = null;

    for (proc.instances) |*inst| {
        if (inst.status == .running) {
            running_count += 1;
            if (main_pid == null) main_pid = inst.pid;
        }
    }

    if (main_pid) |pid| {
        log.info("   Main PID: {d}", .{pid});
    }

    log.info("      Tasks: {d} (instances: {d} running/{d} total)", .{ running_count, running_count, proc.instances.len });

    // Add blank line for readability
    log.info("", .{});
}
