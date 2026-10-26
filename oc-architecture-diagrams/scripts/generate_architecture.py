#!/usr/bin/env python3
"""Generate Stage 1 and Stage 2 Mermaid Markdown from config/architecture.yaml."""
from pathlib import Path
import argparse
import re
import yaml

ROOT = Path(__file__).resolve().parents[1]

def safe_id(value):
    return re.sub(r'[^A-Za-z0-9_]', '_', value)

def quoted(value):
    return str(value).replace('\\', '\\\\').replace('"', '&quot;').replace('\n', ' ')

def validate(stages):
    if not isinstance(stages, list) or not stages:
        raise ValueError('stages must be a nonempty list')
    ids = [s['id'] for s in stages]
    if len(set(ids)) != len(ids):
        raise ValueError('Stage IDs must be unique')
    for s in stages:
        if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_]*', s['id']):
            raise ValueError(f"Invalid stage ID: {s['id']}")
        if not isinstance(s.get('components'), list):
            raise ValueError(f"components must be a list for {s['id']}")

def generate(config):
    stages = config['stages']
    validate(stages)
    title = config.get('project', 'Architecture')
    high = ['flowchart LR']
    for s in stages:
        high.append(f'    {s["id"]}["{quoted(s["name"])}"]')
    for a, b in zip(stages, stages[1:]):
        high.append(f'    {a["id"]} --> {b["id"]}')
    detail = ['flowchart LR']
    for s in stages:
        sid = s['id']
        detail.append(f'    subgraph {sid}["{quoted(s["name"])}"]')
        detail.append('        direction TB')
        if not s['components']:
            detail.append(f'        {sid}_empty["No components configured"]')
        for i, component in enumerate(s['components'], start=1):
            detail.append(f'        {sid}_{i}["{quoted(component)}"]')
        detail.append('    end')
    for a, b in zip(stages, stages[1:]):
        detail.append(f'    {a["id"]} --> {b["id"]}')
    return {
        '01_high_level_architecture.md': f'# {title} — Stage 1: High-Level Architecture\n\n```mermaid\n' + '\n'.join(high) + '\n```\n',
        '02_component_architecture.md': f'# {title} — Stage 2: Component Architecture\n\n```mermaid\n' + '\n'.join(detail) + '\n```\n',
    }

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=ROOT / 'config' / 'architecture.yaml')
    parser.add_argument('--output', type=Path, default=ROOT / 'docs')
    args = parser.parse_args()
    with args.config.open(encoding='utf-8') as f:
        config = yaml.safe_load(f)
    files = generate(config)
    args.output.mkdir(parents=True, exist_ok=True)
    for name, content in files.items():
        dest = args.output / name
        dest.write_text(content, encoding='utf-8')
        print(f'Generated: {dest}')

    # Embed the same generated Mermaid blocks in the GitLab landing README.
    readme_path = ROOT / 'README.md'
    readme = readme_path.read_text(encoding='utf-8')
    for marker, filename in [
        ('STAGE_1', '01_high_level_architecture.md'),
        ('STAGE_2', '02_component_architecture.md'),
    ]:
        start = f'<!-- BEGIN GENERATED {marker} -->'
        end = f'<!-- END GENERATED {marker} -->'
        if readme.count(start) != 1 or readme.count(end) != 1:
            raise ValueError(f'Missing or duplicate README markers: {marker}')
        mermaid_block = files[filename].split('```mermaid', 1)[1].split('```', 1)[0]
        replacement = f'{start}\n```mermaid{mermaid_block}```\n{end}'
        readme = readme.split(start, 1)[0] + replacement + readme.split(end, 1)[1]
    readme_path.write_text(readme, encoding='utf-8')
    print(f'Updated: {readme_path}')

if __name__ == '__main__':
    main()
