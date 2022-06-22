const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const net = std.net;
const os = std.os;
const assert = std.debug.assert;

const simulator = @import("simulator.zig");
const vsr = @import("vsr.zig");

const default_send_address = net.Address.initIp4([4]u8{ 65, 21, 207, 251 }, 5555);

const usage = fmt.comptimePrint(
    \\Usage:
    \\
    \\  vopr [-h | --help]
    \\
    \\Options:
    \\
    \\  -h, --help
    \\        Print this help message and exit.
    \\
    \\  --seed=<integer>
    \\        Set the seed to a provided 64-bit unsigned integer.
    \\        By default the VOPR will run a specified seed in debug mode.
    \\        If this option is omitted, a series of random seeds will be generated.
    \\
    \\  --send[=<address>]
    \\        When set, the send option opts in to send any bugs found by the VOPR to the VOPR Hub.
    \\        The VOPR Hub will then automatically create a GitHub issue if it can verify the bug.
    \\        The VOPR Hub's address is already present as the default address.
    \\        You can optionally supply an IPv4 addresses for the VOPR Hub if needed.
    \\        If this option is omitted, any bugs that are found will replay locally in Debug mode.
    \\
    \\  --build-mode=<mode>
    \\        Set the build mode for the VOPR. Accepts either ReleaseSafe or Debug.
    \\        By default when no seed is provided the VOPR will run in ReleaseSafe mode.
    \\        By default when a seed is provided the VOPR will run in Debug mode.
    \\        Debug mode is only a valid build mode if a seed is also provided.
    \\
    \\  --simulations=<integer>
    \\        Set the number of times for the simulator to run when using randomly generated seeds.
    \\        By default 1000 random seeds will be generated.
    \\        This flag can only be used with ReleaseSafe mode and when no seed has been specified.
    \\
    \\Example:
    \\
    \\  vopr --seed=123 --send=127.0.0.1:5555 --build-mode=ReleaseSafe
    \\  vopr --simulations=10 --send --build-mode=Debug
    \\
, .{});

// The Report struct contains all the information to be sent to the VOPR Hub.
const Report = struct {
    bug: u8,
    seed: u64,
    commit: [20]u8,
};

const Flags = struct {
    seed: ?u64,
    send_address: ?net.Address, // A null value indicates that the send fag is not set.
    build_mode: std.builtin.Mode,
    simulations: u32,
};

const Bug = enum(u8) {
    crash = 127, // Any assertion crash will be given an exit code of 127 by default.
    liveness = 128,
    correctness = 129,
};

pub fn main() void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const args = parse_args(allocator) catch |err| {
        fatal("unable to parse the VOPR's arguments: {}", .{err});
    };

    // If a seed is provided as an argument then replay the seed, otherwise test a 1,000 seeds:
    if (args.seed) |seed| {
        // Build in fast ReleaseSafe mode if required, useful where you don't need debug logging:
        if (args.build_mode != .Debug) {
            std.debug.print("Replaying seed {} in ReleaseSafe mode...\n", .{seed});
            _ = run_simulator(allocator, seed, .ReleaseSafe, args.send_address);
        } else {
            std.debug.print(
                "Replaying seed {} in Debug mode with full debug logging enabled...\n",
                .{seed},
            );
            _ = run_simulator(allocator, seed, .Debug, args.send_address);
        }
    } else if (args.build_mode == .Debug) {
        fatal("no seed provided: the VOPR must be run with --mode=ReleaseSafe", .{});
    } else {
        // Run the simulator with randomly generated seeds.
        var i: u32 = 0;
        while (i < args.simulations) : (i += 1) {
            const seed_random = std.crypto.random.int(u64);
            const exit_code = run_simulator(
                allocator,
                seed_random,
                .ReleaseSafe,
                args.send_address,
            );
            if (exit_code != null) {
                // If a seed fails exit the loop.
                break;
            }
        }
    }
}

// Runs the simulator as a child process.
// Reruns the simulator in Debug mode if a seed fails in ReleaseSafe mode.
fn run_simulator(
    allocator: mem.Allocator,
    seed: u64,
    mode: std.builtin.Mode,
    send_address: ?net.Address,
) ?Bug {
    var seed_str = std.ArrayList(u8).init(allocator);
    defer seed_str.deinit();

    fmt.formatInt(seed, 10, .lower, .{}, seed_str.writer()) catch |err| switch (err) {
        error.OutOfMemory => fatal("unable to format seed as an int. Error: {}", .{err}),
    };
    const mode_str = switch (mode) {
        .Debug => "-ODebug",
        .ReleaseSafe => "-OReleaseSafe",
        else => unreachable,
    };

    // The child process executes zig run instead of zig build. Otherwise the build process is
    // interposed between the VOPR and the simulator and its exit code is returned instead of the
    // simulator's exit code.
    const exit_code = run_child_process(
        allocator,
        &.{ "zig/zig", "run", mode_str, "./src/simulator.zig", "--", seed_str.items },
    );

    const result = switch (exit_code) {
        0 => null,
        127 => Bug.crash,
        128 => Bug.liveness,
        129 => Bug.correctness,
        else => {
            std.debug.print("unexpected simulator exit code: {}", .{exit_code});
            @panic("unexpected simulator exit code.");
        },
    };

    if (result) |bug| {
        if (mode == .ReleaseSafe) {
            std.debug.print("simulator exited with exit code {}.\n", .{@enumToInt(bug)});
            std.debug.print("rerunning seed {} in Debug mode.\n", .{seed});
            assert(bug == run_simulator(allocator, seed, .Debug, send_address).?);
        } else {
            if (send_address) |hub_address| {
                send_report(allocator, hub_address, bug, seed);
            }
        }
    }
    return result;
}

// Initializes and executes the simulator as a child process.
// Terminates the VOPR if the simulator fails to run or exits without an exit code.
fn run_child_process(allocator: mem.Allocator, argv: []const []const u8) u8 {
    const child_process = std.ChildProcess.init(argv, allocator) catch |err| {
        fatal("unable to initialize simulator as a child process. Error: {}", .{err});
    };
    defer child_process.deinit();

    child_process.stdout = std.io.getStdOut();
    child_process.stderr = std.io.getStdErr();

    // Using spawn instead of exec because spawn allows output to be streamed instead of buffered.
    const term = child_process.spawnAndWait() catch |err| {
        fatal("unable to run the simulator as a child process. Error: {}", .{err});
    };

    switch (term) {
        .Exited => |code| {
            std.debug.print("exit with code: {}\n", .{code});
            return code;
        },
        else => {
            fatal("the simulator exited without an exit code. Term: {}\n", .{term});
        },
    }
}

// Sends a bug report to the VOPR Hub.
// The VOPR Hub will attempt to verify the bug and automatically create a GitHub issue.
fn send_report(allocator: mem.Allocator, address: net.Address, bug: Bug, seed: u64) void {
    var message: Report = create_report(allocator, bug, seed);
    var byte_array: [29]u8 = undefined;

    // Bug type
    assert(message.bug == 1 or message.bug == 2 or message.bug == 3);

    // Seed
    var seed_integer_value: u64 = message.seed;
    // Zig stores value as Little Endian when VOPR Hub is expecting Big Endian.
    seed_integer_value = @byteSwap(u64, seed_integer_value);
    const seed_byte_array: [8]u8 = @bitCast([8]u8, seed_integer_value);

    byte_array[0] = message.bug;
    var offset: usize = 1;
    mem.copy(u8, byte_array[offset..], &seed_byte_array);
    offset = offset + seed_byte_array.len;
    mem.copy(u8, byte_array[offset..], &message.commit);

    // Send message
    const stream = net.tcpConnectToAddress(address) catch |err| {
        fatal("unable to create a connection to the VOPR Hub. Error: {}", .{err});
    };

    std.debug.print("Connected to VOPR Hub.", .{});

    var writer = stream.writer();
    writer.writeAll(&byte_array) catch |err| {
        fatal("unable to send the report to the VOPR Hub. Error: {}", .{err});
    };

    // Receive reply
    var reply: [1]u8 = undefined;
    var reader = stream.reader();
    var bytes_read = reader.readAll(&reply) catch |err| {
        fatal("unable to read a reply from the VOPR Hub. Error: {}", .{err});
    };
    if (bytes_read > 0) {
        std.debug.print("Confirmation received from VOPR Hub: {s}.", .{reply});
    } else {
        std.debug.print("No reply received from VOPR Hub.", .{});
    }
}

// Creating a single report struct that contains all information required for the VOPR Hub.
fn create_report(allocator: mem.Allocator, bug: Bug, seed: u64) Report {
    std.debug.print("Collecting VOPR bug and seed, and the current git commit hash.\n", .{});

    // Setting the bug type.
    var bug_type: u8 = undefined;
    switch (bug) {
        .correctness => bug_type = 1,
        .liveness => bug_type = 2,
        .crash => bug_type = 3,
    }

    assert(bug_type != undefined);

    // Running git log to extract the current TigerBeetle git commit hash from stdout.
    var args = [3][]const u8{ "git", "log", "-1" };
    var exec_result = std.ChildProcess.exec(.{
        .allocator = allocator,
        .argv = &args,
    }) catch |err| {
        fatal("unable to extract TigerBeetle's git commit hash. Error: {}", .{err});
    };

    var git_log = exec_result.stdout;
    std.debug.print("git commit that was retrieved: {s}\n", .{git_log[7..47].*});

    var commit_string = git_log[7..47].*;
    var commit_byte_array: [20]u8 = undefined;
    _ = fmt.hexToBytes(&commit_byte_array, &commit_string) catch |err| {
        fatal("unable to cast the git commit hash to hex. Error: {}", .{err});
    };

    return Report{
        .bug = bug_type,
        .seed = seed,
        .commit = commit_byte_array,
    };
}

/// Format and print an error message followed by the usage string to stderr,
/// then exit with an exit code of 1.
fn fatal(comptime fmt_string: []const u8, args: anytype) noreturn {
    const stderr = std.io.getStdErr().writer();
    stderr.print("error: " ++ fmt_string ++ "\n", args) catch {};
    os.exit(1);
}

/// Parse e.g. `--seed=123` into 123 with error handling.
fn parse_flag(comptime flag: []const u8, arg: [:0]const u8) [:0]const u8 {
    const value = arg[flag.len..];
    if (value.len < 2) {
        fatal("{s} argument requires a value", .{flag});
    }
    if (value[0] != '=') {
        fatal("expected '=' after {s} but found '{c}'", .{ flag, value[0] });
    }
    return value[1..];
}

// Parses the VOPR arguments to set flag values, otherwise uses default flag values.
fn parse_args(allocator: mem.Allocator) !Flags {
    // Set default values
    var flags = Flags{
        .seed = null,
        .send_address = null,
        .build_mode = undefined,
        .simulations = 1000,
    };

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Keep track of the args from the ArgIterator above that were allocated
    // then free them all at the end of the scope.
    var args_allocated = std.ArrayList([:0]const u8).init(allocator);
    defer {
        for (args_allocated.items) |arg| allocator.free(arg);
        args_allocated.deinit();
    }

    // Skip argv[0] which is the name of this executable
    assert(args.skip());

    while (args.next(allocator)) |arg_next| {
        const arg = try arg_next;
        try args_allocated.append(arg);

        if (mem.startsWith(u8, arg, "--seed")) {
            const seed_string = parse_flag("--seed", arg);
            flags.seed = simulator.parse_seed(seed_string);
            // If a seed is supplied Debug becomes the default mode.
            if (flags.build_mode == undefined) {
                flags.build_mode = .Debug;
            }
        } else if (mem.startsWith(u8, arg, "--send")) {
            if (mem.eql(u8, arg, "--send")) {
                // If --send is set and no address is supplied then use default address
                flags.send_address = default_send_address;
            } else {
                const str_address = parse_flag("--send", arg);
                flags.send_address = try vsr.parse_address(str_address);
            }
        } else if (mem.startsWith(u8, arg, "--build-mode")) {
            if (mem.eql(u8, parse_flag("--build-mode", arg), "ReleaseSafe")) {
                flags.build_mode = .ReleaseSafe;
            } else if (mem.eql(u8, parse_flag("--build-mode", arg), "Debug")) {
                flags.build_mode = .Debug;
            } else {
                fatal(
                    "unsupported build mode: {s}. Use either ReleaseSafe or Debug mode.",
                    .{arg},
                );
            }
        } else if (mem.startsWith(u8, arg, "--simulations")) {
            const num_simulations_string = parse_flag("--simulations", arg);
            flags.simulations = std.fmt.parseUnsigned(u32, num_simulations_string, 10) catch |err| switch (err) {
                error.Overflow => @panic("the number of simulations exceeds a 16-bit unsigned integer"),
                error.InvalidCharacter => @panic("the number of simulations contains an invalid character"),
            };
        } else if (mem.eql(u8, arg, "-h") or mem.eql(u8, arg, "--help")) {
            std.io.getStdOut().writeAll(usage) catch os.exit(1);
            os.exit(0);
        } else if (mem.startsWith(u8, arg, "--")) {
            fatal("unexpected argument: '{s}'", .{arg});
        } else {
            fatal("unexpected argument: '{s}' (must start with '--')", .{arg});
        }
    }

    // Build mode is set last to ensure that if a seed is passed to the VOPR the Debug default
    // doesn't override a user specified mode.
    if (flags.build_mode == undefined) {
        flags.build_mode = .ReleaseSafe;
    }

    if (flags.seed == null and flags.build_mode != .ReleaseSafe) {
        fatal("random seeds must be run in ReleaseSafe mode.", .{});
    }

    return flags;
}