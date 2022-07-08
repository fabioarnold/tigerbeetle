# VOPR Hub

*When a VOPR is run with the `send` flag and a seed fails, it will send a bug report to the VOPR Hub. The VOPR Hub then replays the seed locally in `Debug` mode and collects the logs in order to automatically create a GitHub issue.*

## The VOPR

*The Viewstamped Operation Replicator* provides deterministic simulation testing for TigerBeetle. It tests that clusters of TigerBeetle servers and clients interact correctly according to TigerBeetle's Viewstamped Replication consensus protocol, even under the pressure of simulated network and storage faults, and it checks each replica's state after each transition.

The VOPR has an optional `--send` flag that enables it to send bug reports to the VOPR Hub. This flag can only be used when all code has been committed and pushed. For the VOPR Hub to replay a failing seed it needs to run that seed on the same commit to get the same result.

If the VOPR discovers a failing seed it creates a bug report in the format of a fixed length byte array.

* 16 bytes contain the first half of a SHA256 hash of the remainder of the message.
* 1 byte indicates the type of bug detected (correctness, liveness, or crash).
* 8 bytes are reserved for the seed.
* The final 20 bytes contain the hash of the git commit that the test was run on.

## VOPR Hub Steps

The VOPR Hub listens for bug reports sent by any VOPR via TCP.

### Validation

When the VOPR Hub receives a message it first validates it. Messages are expected to be exactly 45 bytes in length. The VOPR Hub hashes the last 29 bytes of the message and ensures the first half that SHA256 hash matches the first 16 bytes of the message. This guards against decoding random traffic that arrives at the server. If the hash is correct then the VOPR Hub checks that the first byte (representing the bug type) is between 1 and 3 and that the 8 bytes that represent the seed can be converted to an unsigned integer. The remaining 20 bytes are the GitHub commit hash and should all be able to be decoded to valid hex characters.

Once validated the message is decoded and added to a queue for processing.

### Replies to the VOPR

Once the message is determined to be valid then a reply of "1" is sent back to the VOPR and the connection is closed. If it's invalid, the connection is simply closed and no further processing is required.

### Message Processing

When the VOPR Hub replays a seed it will save the logs to disk. This way each issue can be tracked to see if it has already been submitted. For correctness bugs (bug 1) and liveness bugs (bug 2) the file name is simply bug_seed_commithash. Correctness and liveness bugs can be deduped immediately by checking for their file name on disk. Crash bugs (bug 3) do not include the seed in their file name but do have an additional field which is the hash of the stack trace of the issue (bug_commithash_stacktracehash). Therefore they can only be deduped after the seed has been replayed and logs have been generated.

If no duplicate issue has been found then the VOPR Hub will replay the seed in Debug mode and capture the logs. In order to do this it must first checkout the correct git commit. This step requires that the reported commit is available on the tigerbeetle repository.

### Create an Issue

Once the simulation has completed the stack trace is extracted and parsed to remove the directory structure and any memory addresses so that it is made to be deterministic. This way it can be hashed and used to dedupe any crash bugs that may have already been logged. Crash bugs include a hash of the stack trace in their filename to deduplicate assertion crashes for the same call graph. However, we do not do this for correctness bugs, since these are always detected by the same set of panics in the simulator, but may have different reasons for reaching them.

A copy of the issue is written to disk and a GitHub issue is also automatically generated. The issue contains the bug type, seed, commit hash, parameters of the VOPR, stack trace (if there is one), debug logs, and a timestamp.

Note that if the VOPR Hub replays a seed and it passes unexpectedly then an issue will still be created with a note explaining that the seed passed.
