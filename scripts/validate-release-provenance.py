#!/usr/bin/env python3
"""Validate the pull request and CI evidence for an immutable release commit."""

def validate_release(commit, pull_requests, actor, runs, tag_commit=None):
    if tag_commit is not None and tag_commit != commit:
        raise ValueError("Release tag must match the frozen merge commit")
    matching = [pr for pr in pull_requests if pr.get('merged_at')
                and pr.get('merge_commit_sha') == commit
                and pr.get('base', {}).get('ref') == 'main']
    if len(matching) != 1:
        raise ValueError('Release commit must identify exactly one merged pull request to main')
    pr = matching[0]
    if actor != "rmarinsky" or pr.get("merged_by", {}).get("login") != "rmarinsky":
        raise ValueError("Only rmarinsky may merge and initiate a release")
    exact_runs = [run for run in runs if run.get('head_sha') == commit and run.get('event') == 'push'
                  and run.get('head_branch') == 'main']
    latest = max(exact_runs, key=lambda run: (run.get('id', 0), run.get('run_attempt', 1)), default={})
    if latest.get('status') != 'completed' or latest.get('conclusion') != 'success':
        raise ValueError('Release commit requires successful CI on the exact commit')
    return pr['number']


def github_pages(endpoint):
    import json
    import subprocess
    result = subprocess.run(['gh', 'api', '--paginate', '--slurp', endpoint],
                            check=True, capture_output=True, text=True)
    return json.loads(result.stdout)


def main():
    import argparse
    import re
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('repository')
    parser.add_argument('commit')
    parser.add_argument('actor')
    parser.add_argument('--tag-commit')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', args.repository) or not re.fullmatch(r'[0-9a-f]{40}', args.commit):
        parser.error('Expected owner/repository and a full commit SHA')
    prefix = f'repos/{args.repository}'
    associated = [pr for page in github_pages(f'{prefix}/commits/{args.commit}/pulls?per_page=100') for pr in page]
    pull_requests = [github_pages(f"{prefix}/pulls/{pr['number']}")[0] for pr in associated]
    runs = [run for page in github_pages(f'{prefix}/actions/workflows/ci.yml/runs?head_sha={args.commit}&event=push&per_page=100')
            for run in page['workflow_runs']]
    number = validate_release(args.commit, pull_requests, args.actor, runs, args.tag_commit)
    print(f'Frozen PR #{number} and successful CI verified for {args.commit}')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, RuntimeError) as error:
        raise SystemExit(str(error))
