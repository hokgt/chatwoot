#!/usr/bin/env python3
"""Restore the proxy_https production hook and deploy override idempotently."""
import os
import sys
import tempfile
from pathlib import Path

TARGET = Path("config/environments/production.rb")
COMPOSE_TARGET = Path("docker-compose.deploy.yaml")
UPSTREAM = """  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  config.force_ssl = ActiveModel::Type::Boolean.new.cast(ENV.fetch('FORCE_SSL', false))
"""
BLOCK = """  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  # WIJAYA_CUSTOM_START proxy_https
  require Rails.root.join('custom/wijaya/batteries/proxy_https/policy')
  Wijaya::Batteries::ProxyHttps::Policy.apply!(config)
  # WIJAYA_CUSTOM_END proxy_https
"""
COMPOSE_ANCHOR = """      - INSTALLATION_ENV=docker
      # Explicit default-deny allowlist of trusted internal hosts the API-inbox webhook
"""
COMPOSE_BLOCK = """      - INSTALLATION_ENV=docker
      - FORCE_SSL=true
      # Explicit default-deny allowlist of trusted internal hosts the API-inbox webhook
"""


class PatchError(Exception):
    pass


def patched(content):
    if content.count(BLOCK) == 1:
        return content
    if 'WIJAYA_CUSTOM_START proxy_https' in content or 'WIJAYA_CUSTOM_END proxy_https' in content:
        raise PatchError('partial or modified proxy_https marker block')
    if content.count(UPSTREAM) != 1:
        raise PatchError('production SSL anchor is missing or ambiguous')
    return content.replace(UPSTREAM, BLOCK, 1)


def compose_patched(content):
    if content.count(COMPOSE_BLOCK) == 1:
        return content
    if '      - FORCE_SSL=true\n' in content:
        raise PatchError('partial, duplicate, or misplaced FORCE_SSL deploy override')
    if content.count(COMPOSE_ANCHOR) != 1:
        raise PatchError('Rails deploy environment anchor is missing or ambiguous')
    return content.replace(COMPOSE_ANCHOR, COMPOSE_BLOCK, 1)


def atomic_write(path, content):
    fd, temporary = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as handle:
            handle.write(content)
        os.chmod(temporary, path.stat().st_mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def apply(root, check=False):
    root = Path(root)
    path = root / TARGET
    compose_path = root / COMPOSE_TARGET
    original = path.read_text()
    compose_original = compose_path.read_text()
    updated = patched(original)
    compose_updated = compose_patched(compose_original)
    changed = updated != original or compose_updated != compose_original

    if not changed:
        print('proxy_https hook and deploy override already present')
        return False
    if check:
        raise PatchError('check mode: proxy_https hook or deploy override would be patched')

    if updated != original:
        atomic_write(path, updated)
        print(f'proxy_https hook applied: {TARGET}')
    if compose_updated != compose_original:
        atomic_write(compose_path, compose_updated)
        print(f'proxy_https deploy override applied: {COMPOSE_TARGET}')
    return True


def main():
    root = Path(__file__).resolve().parents[5]
    try:
        apply(root)
    except (OSError, PatchError) as error:
        print(f'proxy_https patch error: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
