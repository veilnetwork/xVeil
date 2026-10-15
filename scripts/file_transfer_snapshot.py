"""Freeze competing-file evidence while the caller holds its callback lock."""
import hashlib


def snapshot_transfers(progress, chunks, payloads, auth_errors, duplicates,
                       send_failures, chunk_bytes=2048):
    results = []
    for side, received in enumerate(chunks):
        expected = payloads[1 - side]
        count = len(expected) // chunk_bytes
        missing = sorted(set(range(count)) - received.keys())
        complete = not missing and len(received) == count
        valid = complete and hashlib.sha256(
            b''.join(received[i] for i in range(count))
        ).digest() == hashlib.sha256(expected).digest()
        results.append(dict(progress[side],
                            received=sum(len(value) for value in received.values()),
                            missing_chunks=len(missing), missing_indices=missing,
                            hash_matches=bool(valid)))
    return dict(file_results=results, file_auth_errors=list(auth_errors),
                file_duplicates=list(duplicates),
                file_async_send_failures=[dict(row) for row in send_failures])
