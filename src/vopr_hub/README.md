VOPR Hub

The VOPR Hub recieves bug reports from VOPRs. It reruns these bugs locally in Debug mode and collects the logs in order to automatically create GitHub issues with the logs.

The VOPR Hub listens out for bug reports sent by the VOPR via TCP.

The VOPR has an optional --send flag that enables it to send bugs to the VOPR Hub. This flag can only be used when all code has been commiteed and pushed as the same GitHub commit hash must be accessible by the VOPR Hub for it to successfully rerun seeds.

Messages take the format:
    bug - where 1 indicates a correctness bug, 2 a liveness bug and 3 a crash.
    The seed that failed
    the GitHub commit hash that was used for running the VOPR

When the VOPR Hub receives a message it first validates it.
The message is a fixed-size 45 byte byte array.
The first 16 bytes are the first half of a SHA256 hash of the remaining 29 bytes.
The next byte should be an integer between 1 and three.
The next 8 bytes should be an integer reflecting the seed.
The remaining 20 bytes are the GitHub commit hash and should all be valid hex characters.

Once the message is determined to be valid then a reply (1) is sent to the VOPR that sent the message and the connection is closed. If it's invalid the connection is simply closed.

The message has now been decoded and is added to a queue for processing.

The VOPR Hub has a Go Routine running that constantly checks if there are messages waiting in the queue. If there is a message it begins processing.

First the messages are deduped if an issue withat seed and commit hash already exist.

Checkout commit if found on repo (if not found then just write to server activity logs that captures activity)

Run VOPR with seed in debug mode. If the seed succeeds for some reason then just write to server activity logs.

Extract and parse stack trace if there is one - want to remove the directory info that reflects the structure on the specific machine (i.e. up until and including the tigerbeetle directory, and remove memory addresses). The point of this is to get a deterministic version of the stack trace.

Hash the stack trace.

Generate the file name: 
1_seed_commithash(correctness)
2_seed_commithash (liveness)
3_commithash_stacktracehash (crash) (multiple seeds for the same commit can give the same stack trace, but if only use stack trace then a liveness bug can come back again and we risk ignoring it even though it reappeared.)

A copy of the issue is written to disk.

Create GitHub issue even if the seed unexpectedly passes. Issue contains bug type, seed, commit hash, parameters for the VOPR, stack trace if there is one, debug logs and timestamp.
