const std = @import("std");
const mem = std.mem;
const heap = std.heap;
const Thread = std.Thread;
const posix = std.posix;
const AutoArrayHashMapUnmanaged = std.AutoArrayHashMapUnmanaged;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const HashMap = std.StringArrayHashMapUnmanaged;

const common = @import("common");
const Config = common.Config;
const Logger = common.Logger;

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
logger: *Logger,

pub const ProcessChild = struct {
    parent: *Process,
    index: usize,
};

pub fn init(gpa: mem.Allocator, config_file_path: []const u8, logger: *Logger) ProcessManager {
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
        .logger = logger,
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
        const proc = try Process.create(self.gpa, self.logger);
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
        if (inst.status == .stopped or inst.status == .exited or inst.status == .fatal) {
            self.logger.info("starting process {s}[{d}] (current status: {s})", .{ proc.config.name, i, @tagName(inst.status) });
            try inst.start(&proc.config, arena);
            try self.updateLivePid(inst, proc, i);
        } else {
            self.logger.debug("skipping start of process {s}[{d}] - already in status: {s}", .{ proc.config.name, i, @tagName(inst.status) });
        }
    }
}

fn restartProcess(self: *ProcessManager, proc: *Process) !void {
    try self.stopProcess(proc);
    try self.startProcess(proc);
}

fn updateLivePid(self: *ProcessManager, child: *const Child, proc: *Process, index: usize) !void {
    if (child.pid) |pid| {
        try self.live_pid.put(self.gpa, pid, .{ .parent = proc, .index = index });
        self.logger.debug("updated live PID tracking: pid={d} for process {s}[{d}]", .{ pid, proc.config.name, index });
    } else {
        self.logger.warn("attempted to update live PID tracking but child has no PID for process {s}[{d}]", .{ proc.config.name, index });
    }
}

fn removeLivePid(self: *ProcessManager, pid: posix.pid_t) void {
    if (self.live_pid.swapRemove(pid)) {
        self.logger.debug("removed PID {d} from live tracking", .{pid});
    } else {
        self.logger.warn("attempted to remove PID {d} but it was not being tracked", .{pid});
    }
}

fn manageProcess(self: *ProcessManager, proc: *Process) !void {
    const now: u64 = @intCast(std.time.milliTimestamp());

    for (proc.instances, 0..) |*child, i| {
        if (child.pid) |pid| {
            if (child.poll()) |result| {
                if (result != null) {
                    self.removeLivePid(pid);
                    self.logger.info("detected exit of process {s}[{d}] pid={d}", .{ proc.config.name, i, pid });
                }
            } else |err| {
                self.logger.err("failed to poll process {s}[{d}] pid={d}: {}", .{ proc.config.name, i, pid, err });

                child.finalizeExit(null, null);
                self.removeLivePid(pid);
            }
        } else if (child.status == .running) {
            self.logger.warn("process {s}[{d}] has status=running but no PID, marking as exited", .{ proc.config.name, i });
            child.status = .exited;
        }

        switch (child.status) {
            .starting => {
                if ((now - child.last_start_time) >= (proc.config.conf.starttime * 1000)) {
                    if (child.pid) |pid| {
                        // Check if process already exited during startup (status changed by polling)
                        if (child.status != .starting) {
                            // Status was changed by polling - likely .exited, skip transition
                            continue;
                        }

                        if (posix.kill(pid, 0)) |_| {
                            child.status = .running;
                            try self.updateLivePid(child, proc, i);
                            self.logger.info("process {s}[{d}] marked as successfully started", .{ proc.config.name, i });
                        } else |err| switch (err) {
                            error.ProcessNotFound => {
                                child.status = .exited;
                                self.removeLivePid(pid);
                                self.logger.warn("process {s}[{d}] died during startup period", .{ proc.config.name, i });
                            },
                            else => {
                                self.logger.debug("could not verify process {s}[{d}] status: {}", .{ proc.config.name, i, err });
                            },
                        }
                    } else {
                        child.status = .fatal;
                        self.logger.err("process {s}[{d}] has no PID after startup period", .{ proc.config.name, i });
                    }
                }
            },
            .backoff => {
                if (child.backoff_until) |until| {
                    if (now >= until) {
                        const should_restart = switch (proc.config.conf.autorestart) {
                            .always => true,
                            .unexpected => if (child.exit_code) |code| !proc.isExpectedExitCode(code) else true,
                            .never => false,
                        };

                        if (should_restart and child.retries < proc.config.conf.startretries) {
                            child.backoff_until = null;
                            try child.restart(&proc.config, proc.arena.allocator());
                            try self.updateLivePid(child, proc, i);
                        } else {
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
                    try child.restart(&proc.config, proc.arena.allocator());
                    try self.updateLivePid(child, proc, i);
                } else if (!should_restart) {
                    child.status = .stopped;
                } else {
                    child.status = .fatal;
                }
            },
            .running => {},
            .stopping => {},
            .stopped => {},
            .fatal => {},
        }
    }
}

fn monitorProcesses(self: *ProcessManager) !void {
    var it = self.live.iterator();
    while (it.next()) |entry| {
        try self.manageProcess(entry.value_ptr.*);
    }
}

fn mainLoop(self: *ProcessManager) !void {
    const logger = self.logger;
    var fatal_error: anyerror = undefined;
    var current_parsed_result: Config.ParsedResult = .empty;
    defer current_parsed_result.deinit();
    var new_config_staging: HashMap(*Process) = .empty;
    errdefer self.cleanupStagedConfig(&new_config_staging);
    var local_command: common.Command = undefined;
    var local_command_payload: [256]u8 = undefined;

    state: switch (Status.process_manager_needs_to_load_the_inial_config) {
        .process_manager_needs_to_load_the_inial_config => {
            logger.info("state=LOAD_INITIAL_CONFIG", .{});
            if (self.stopping.load(.acquire)) continue :state .process_manager_needs_to_shutdown;

            if (self.loadConfig()) |result| {
                logger.info("config loaded successfully", .{});
                current_parsed_result = result;
                current_parsed_result.valid = true;
                continue :state .process_manager_needs_to_stage_the_new_config;
            } else |err| {
                logger.err("config load failed: {}", .{err});
                fatal_error = err;
                continue :state .process_manager_failed_to_load_config;
            }
        },

        .process_manager_needs_to_load_a_config => {
            logger.info("state=LOAD_CONFIG", .{});
            if (self.stopping.load(.acquire)) continue :state .process_manager_needs_to_shutdown;

            current_parsed_result.deinit();
            current_parsed_result = .empty;
            current_parsed_result.valid = false;

            if (self.config.parseLeaky(self.gpa)) |result| {
                logger.info("config loaded successfully", .{});
                current_parsed_result = result;
                current_parsed_result.valid = true;
                continue :state .process_manager_needs_to_stage_the_new_config;
            } else |err| {
                logger.err("config load failed: {}", .{err});
                fatal_error = err;
                continue :state .process_manager_failed_to_load_config;
            }
        },

        .process_manager_needs_to_stage_the_new_config => {
            logger.info("state=STAGE_NEW_CONFIG", .{});
            if (self.stopping.load(.acquire)) continue :state .process_manager_needs_to_shutdown;

            if (self.stageNewConfig(&current_parsed_result)) |new_config| {
                logger.info("staged new config successfully ({} processes)", .{new_config.count()});
                new_config_staging = new_config;
                continue :state .process_manager_needs_to_commit_the_new_config;
            } else |err| {
                logger.err("staging config failed: {}", .{err});
                fatal_error = err;
                continue :state .process_manager_failed_to_stage_config;
            }
        },

        .process_manager_needs_to_commit_the_new_config => {
            logger.info("state=COMMIT_NEW_CONFIG", .{});
            if (self.stopping.load(.acquire)) continue :state .process_manager_needs_to_shutdown;

            if (self.commitStagedConfig(&new_config_staging)) |new_live| {
                logger.info("committed new config ({} live processes)", .{new_live.count()});
                self.live = new_live;
                continue :state .process_manager_needs_to_apply_the_new_config;
            } else |err| {
                logger.err("commit config failed: {}", .{err});
                fatal_error = err;
                continue :state .process_manager_failed_to_commit_config;
            }
        },

        .process_manager_needs_to_apply_the_new_config => {
            if (self.stopping.load(.acquire)) continue :state .process_manager_needs_to_shutdown;

            if (self.monitorProcesses()) {
                continue :state .process_manager_needs_to_monitor_processes;
            } else |err| {
                logger.err("apply config failed: {}", .{err});
                fatal_error = err;
                continue :state .process_manager_failed_to_apply_config;
            }
        },

        .process_manager_needs_to_monitor_processes => {
            if (self.stopping.load(.acquire)) continue :state .process_manager_needs_to_shutdown;

            if (self.monitorProcesses()) {
                continue :state .process_manager_needs_to_check_for_new_command;
            } else |err| {
                fatal_error = err;
                continue :state .process_manager_encountered_fatal_error;
            }
        },

        .process_manager_needs_to_check_for_new_command => {
            if (self.stopping.load(.acquire)) continue :state .process_manager_needs_to_shutdown;
            if (self.checkForNewCommand(&local_command, &local_command_payload)) {
                logger.info("state=PM_NEEDS_TO_WAIT_FOR_COMMANDS ", .{});
                continue :state .process_manager_needs_to_route_the_new_command;
            } else {
                Thread.sleep(std.time.ns_per_ms);
                // Go back to monitoring to manage running processes
                continue :state .process_manager_needs_to_monitor_processes;
            }
        },

        .process_manager_needs_to_route_the_new_command => {
            logger.info("state=PM_NEEDS_TO_EXEC_COMMAND", .{});
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
                    logger.info("started {s}", .{name});
                } else |err| {
                    logger.err("failed to start {s}: {}", .{ name, err });
                    fatal_error = err;
                    continue :state .process_manager_encountered_fatal_error;
                }
            } else {
                logger.warn("no process named {s}", .{name});
            }
            continue :state .process_manager_needs_to_check_for_new_command;
        },

        .process_manager_exec_stop => {
            const name = local_command_payload[0..local_command.payload_len];
            if (self.live.get(name)) |proc| {
                if (self.stopProcess(proc)) |_| {
                    logger.info("stopped {s}", .{name});
                } else |err| {
                    logger.err("failed to stop {s}: {}", .{ name, err });
                    fatal_error = err;
                    continue :state .process_manager_encountered_fatal_error;
                }
            } else {
                logger.warn("no process named {s}", .{name});
            }
            continue :state .process_manager_needs_to_check_for_new_command;
        },

        .process_manager_exec_restart => {
            const name = local_command_payload[0..local_command.payload_len];
            if (self.live.get(name)) |proc| {
                if (self.restartProcess(proc)) |_| {
                    logger.info("restarted {s}", .{name});
                } else |err| {
                    logger.err("failed to restart {s}: {}", .{ name, err });
                    fatal_error = err;
                    continue :state .process_manager_encountered_fatal_error;
                }
            } else {
                logger.warn("no process named {s}", .{name});
            }
            continue :state .process_manager_needs_to_check_for_new_command;
        },

        .process_manager_exec_reload => {
            logger.info("reloading config…", .{});
            continue :state .process_manager_reset_config_file_seek_position;
        },

        .process_manager_reset_config_file_seek_position => {
            logger.info("reloading content of config file", .{});
            if (self.config.reload()) {
                continue :state .process_manager_needs_to_load_a_config;
            } else |err| {
                logger.err("failed to reload config {}", .{err});
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
            logger.info("received quit", .{});
            self.stopping.store(true, .release);
            continue :state .process_manager_needs_to_shutdown;
        },

        .process_manager_failed_to_load_config => {
            logger.err("failed to load config: {}", .{fatal_error});
            continue :state .process_manager_encountered_fatal_error;
        },

        .process_manager_failed_to_stage_config => {
            logger.err("failed to stage config: {}", .{fatal_error});
            continue :state .process_manager_encountered_fatal_error;
        },

        .process_manager_failed_to_commit_config => {
            logger.err("failed to commit config: {}", .{fatal_error});
            continue :state .process_manager_encountered_fatal_error;
        },

        .process_manager_failed_to_apply_config => {
            logger.err("failed to apply config: {}", .{fatal_error});
            continue :state .process_manager_encountered_fatal_error;
        },

        .process_manager_encountered_fatal_error => {
            logger.err("fatal error in process manager: {}", .{fatal_error});
            return fatal_error;
        },

        .process_manager_needs_to_shutdown => {
            logger.info("process manager loop shutting down", .{});
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
    process_manager_needs_to_monitor_processes,
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
    const logger = self.logger;
    const status = proc.currentStatus();
    const status_symbol = switch (status) {
        .running => "●",
        .stopped, .exited => "○",
        .fatal => "✗",
        .backoff => "◐",
        .starting => "◐",
        .stopping => "◯",
        else => "◯",
    };

    const status_color = switch (status) {
        .running => "\x1b[32m",
        .stopped, .exited => "\x1b[37m",
        .fatal => "\x1b[31m",
        .backoff, .starting => "\x1b[33m",
        .stopping => "\x1b[35m",
        else => "\x1b[37m",
    };

    const reset_color = "\x1b[0m";

    logger.info("{s}{s}{s} {s} - {s}", .{ status_color, status_symbol, reset_color, proc.config.name, proc.config.conf.cmd });

    logger.info("     Loaded: loaded (command: {s}, numprocs: {d})", .{ proc.config.conf.cmd, proc.config.conf.numprocs });

    const status_str = switch (status) {
        .running => "active (running)",
        .stopped => "inactive (dead)",
        .exited => "inactive (exited)",
        .fatal => "failed (fatal)",
        .backoff => "activating (backoff)",
        .starting => "activating (starting)",
        .stopping => "deactivating (stopping)",
        else => "unknown",
    };

    logger.info("     Active: {s}{s}{s}", .{ status_color, status_str, reset_color });

    var running_count: usize = 0;
    var starting_count: usize = 0;
    var stopping_count: usize = 0;
    var backoff_count: usize = 0;
    var fatal_count: usize = 0;
    var main_pid: ?std.posix.pid_t = null;

    for (proc.instances, 0..) |*inst, i| {
        logger.debug("  Instance[{d}]: status={s}, pid={?d}", .{ i, @tagName(inst.status), inst.pid });
        switch (inst.status) {
            .running => {
                running_count += 1;
                if (main_pid == null) main_pid = inst.pid;
            },
            .starting => starting_count += 1,
            .stopping => stopping_count += 1,
            .backoff => backoff_count += 1,
            .fatal => fatal_count += 1,
            else => {},
        }
    }

    if (main_pid) |pid| {
        logger.info("   Main PID: {d}", .{pid});
    }

    logger.info("      Tasks: {d} running, {d} starting, {d} stopping, {d} backoff, {d} fatal (total: {d})", .{ running_count, starting_count, stopping_count, backoff_count, fatal_count, proc.instances.len });

    logger.info("", .{});
}
