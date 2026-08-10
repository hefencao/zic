#!/usr/bin/env python3
"""Stream-filter ZIC debug JSONL traces into focused diagnostic profiles."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
from typing import Iterable

NETWORK_KINDS = frozenset({
    'pageCurrent',
    'pageTransition',
    'policyDecision',
    'demandDetached',
    'downloadStarted',
    'downloadPriorityChanged',
    'downloadState',
    'artifactSealed',
    'artifactPromoted',
    'resumeAccepted',
    'resumeRestarted',
    'writerRejected',
    'taskFailed',
    'retryScheduled',
    'artifactSource',
    'sourceRead',
    'sourceReady',
})

PLAYBACK_KINDS = frozenset({
    'pageCurrent',
    'pageTransition',
    'policyDecision',
    'firstFrameReady',
    'sourceReady',
    'sourceRead',
    'decodeDemand',
    'decodeRefill',
    'decodeStarted',
    'decodeState',
    'frameDecoded',
    'uploadDemand',
    'uploadStarted',
    'uploadState',
    'frameUploaded',
    'framePresented',
    'framePipelineTiming',
    'playbackFrameDue',
    'playbackBuffering',
    'playbackCompleted',
    'pageOutputReleased',
    'taskFailed',
    'retryScheduled',
})

FAILURE_KINDS = frozenset({
    'taskFailed',
    'writerRejected',
    'sourceDisabled',
    'staleWorkRejected',
    'retryScheduled',
    'resumeRestarted',
})


def _has_error_payload(event: dict[str, object]) -> bool:
    payload = event.get('payload')
    if not isinstance(payload, dict):
        return False
    return any(
        key in payload and payload[key] not in (None, '', False)
        for key in ('error', 'failure', 'exception')
    )


def _matches_profile(event: dict[str, object], profile: str) -> bool:
    if profile == 'all':
        return True
    kind = event.get('kind')
    if not isinstance(kind, str):
        return False
    if profile == 'network':
        return kind in NETWORK_KINDS
    if profile == 'playback':
        return kind in PLAYBACK_KINDS
    if profile == 'failures':
        return kind in FAILURE_KINDS or _has_error_payload(event)
    raise ValueError(f'unknown profile: {profile}')


def _default_output(path: Path, profile: str) -> Path:
    suffix = path.suffix or '.jsonl'
    stem = path.name[:-len(suffix)] if path.suffix else path.name
    return path.with_name(f'{stem}.{profile}{suffix}')


def filter_trace(
    source: Path,
    destination: Path,
    *,
    profile: str,
    identities: Iterable[str] = (),
    sessions: Iterable[str] = (),
) -> tuple[int, int]:
    identity_filters = tuple(item for item in identities if item)
    session_filters = frozenset(item for item in sessions if item)
    read_count = 0
    written_count = 0
    destination.parent.mkdir(parents=True, exist_ok=True)
    with source.open('r', encoding='utf-8') as input_file, destination.open(
        'w', encoding='utf-8', newline='\n'
    ) as output_file:
        for line_number, raw in enumerate(input_file, 1):
            text = raw.strip()
            if not text:
                continue
            read_count += 1
            try:
                event = json.loads(text)
            except json.JSONDecodeError as error:
                raise ValueError(
                    f'{source}:{line_number}: invalid JSON: {error.msg}'
                ) from error
            if not isinstance(event, dict):
                continue
            if not _matches_profile(event, profile):
                continue
            if session_filters and event.get('sessionId') not in session_filters:
                continue
            identity = event.get('identityHash')
            if identity_filters and not (
                isinstance(identity, str)
                and any(fragment in identity for fragment in identity_filters)
            ):
                continue
            output_file.write(text)
            output_file.write('\n')
            written_count += 1
    return read_count, written_count


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description='Stream-filter a ZIC debug trace without loading it all into memory.'
    )
    parser.add_argument('trace', type=Path, help='input .jsonl trace')
    parser.add_argument(
        '--profile',
        choices=('all', 'network', 'playback', 'failures'),
        default='network',
        help='diagnostic profile (default: network)',
    )
    parser.add_argument('-o', '--output', type=Path, help='output .jsonl path')
    parser.add_argument(
        '--identity',
        action='append',
        default=[],
        help='keep identityHash containing this fragment; repeatable',
    )
    parser.add_argument(
        '--session',
        action='append',
        default=[],
        help='keep this exact sessionId; repeatable',
    )
    args = parser.parse_args(argv)
    source = args.trace.resolve()
    if not source.is_file():
        parser.error(f'trace does not exist: {source}')
    destination = (
        args.output.resolve()
        if args.output is not None
        else _default_output(source, args.profile)
    )
    if source == destination:
        parser.error('output must differ from input')
    try:
        read_count, written_count = filter_trace(
            source,
            destination,
            profile=args.profile,
            identities=args.identity,
            sessions=args.session,
        )
    except ValueError as error:
        print(error, file=sys.stderr)
        return 2
    print(
        f'filtered {written_count}/{read_count} events '
        f'({args.profile}) -> {destination}'
    )
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
