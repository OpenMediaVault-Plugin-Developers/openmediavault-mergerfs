#!/usr/bin/env python3
# ui_payloads.py — build RPC payloads exactly the way the workbench UI does,
# by reading the plugin's form and datatable YAML. Used by test-rpc.sh so the
# tests send what the UI sends instead of hand-written payloads.
#
#   ui_payloads.py form create --name N --paths P [--multi null|empty]
#       Payload of the create form, using the YAML defaults.
#   ui_payloads.py form edit < get.json
#       Payload of the edit form, loaded from a Mergerfs.get result.
#   ui_payloads.py actions --uuid U --path P [--deletesource false|true]
#       One JSON object per line ({"desc", "method", "params"}) for every
#       Mergerfs request the datatable page can send, rendered for pool U.
#
# Any template expression this script does not know raises an error, so a
# new UI field or parameter makes the test fail until it is handled here.

import argparse
import json
import os
import re
import sys

import yaml

COMPONENT_DIRS = [
    '/usr/share/openmediavault/workbench/component.d',
    os.path.join(os.path.dirname(os.path.abspath(__file__)), '..',
                 'usr/share/openmediavault/workbench/component.d'),
]
NEW_UUID = os.environ.get('OMV_NEW_UUID', 'fa4b1c66-ef79-11e5-87a0-0002b3a176b4')
TEMPLATE = re.compile(r'^\s*\{\{\s*(.+?)\s*\}\}\s*$')


def load_component(name):
    for d in COMPONENT_DIRS:
        path = os.path.join(d, name + '.yaml')
        if os.path.exists(path):
            with open(path) as f:
                return yaml.safe_load(f)['data']['config']
    sys.exit('component %s not found in %s' % (name, COMPONENT_DIRS))


def render(value, ctx):
    """Render a workbench template value with the given context."""
    if isinstance(value, dict):
        return {k: render(v, ctx) for k, v in value.items()}
    if isinstance(value, list):
        return [render(v, ctx) for v in value]
    if not isinstance(value, str):
        return value
    m = TEMPLATE.match(value)
    if not m:
        return value
    expr = m.group(1)
    if expr not in ctx:
        raise SystemExit('unknown template expression in UI YAML: {{ %s }}' % expr)
    return ctx[expr]


def form_fields(fields):
    """Yield the submitted fields of a form, descending into containers."""
    for field in fields:
        if field.get('type') == 'container':
            yield from form_fields(field.get('fields', []))
            continue
        if field.get('submitValue') is False:
            continue
        if field.get('type') == 'confObjUuid':
            field = dict(field, name='uuid', value='{{ newconfobjuuid }}')
        if field.get('name'):
            yield field


def form_payload(mode, args):
    config = load_component('omv-storage-mergerfs-form-page')
    loaded = json.load(sys.stdin) if mode == 'edit' else {}
    ctx = {'newconfobjuuid': NEW_UUID}
    payload = {}
    for field in form_fields(config['fields']):
        name = field['name']
        multiple = field.get('type') == 'select' and field.get('multiple')
        if mode == 'edit':
            # The form loads the get() result; fields get() does not return
            # are submitted as null (this is what the UI really sends).
            payload[name] = loaded.get(name)
        elif multiple:
            payload[name] = None if args.multi == 'null' else []
        else:
            payload[name] = render(field.get('value'), ctx)
    if mode == 'create':
        payload['name'] = args.name
        payload['paths'] = args.paths
    return payload


def find_requests(node, desc, out):
    """Collect every Mergerfs request in a datatable page config."""
    if isinstance(node, dict):
        label = node.get('tooltip') or node.get('text') or desc
        request = node.get('request')
        if isinstance(request, dict) and request.get('service') == 'Mergerfs':
            out.append((label, request['method'], request.get('params', {}), node))
        proxy = node.get('proxy')
        if isinstance(proxy, dict) and proxy.get('service') == 'Mergerfs':
            get = proxy.get('get', {})
            out.append((label, get.get('method'), get.get('params', {}), node))
        for key, value in node.items():
            if key not in ('request', 'proxy'):
                find_requests(value, label, out)
    elif isinstance(node, list):
        for item in node:
            find_requests(item, desc, out)


def actions(args):
    config = load_component('omv-storage-mergerfs-datatable-page')
    found = []
    find_requests(config, 'page', found)
    ctx = {
        '_selected[0].uuid': args.uuid,
        # Values submitted by the "Remove path" form dialog.
        'uuid': args.uuid,
        'path': args.path,
        'deletesource | toboolean': args.deletesource,
    }
    for desc, method, params, _ in found:
        label = re.sub(r'^_\(["\'](.*)["\']\)$', r'\1', str(desc))
        print(json.dumps({'desc': label, 'method': method,
                          'params': render(params, ctx)}))


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest='cmd', required=True)
    form = sub.add_parser('form')
    form.add_argument('mode', choices=['create', 'edit'])
    form.add_argument('--name', default='')
    form.add_argument('--paths', default='')
    form.add_argument('--multi', choices=['null', 'empty'], default='null')
    act = sub.add_parser('actions')
    act.add_argument('--uuid', required=True)
    act.add_argument('--path', default='/nonexistent')
    # The UI renders "{{ deletesource | toboolean }}" into a string.
    act.add_argument('--deletesource', choices=['false', 'true'], default='false')
    args = parser.parse_args()
    if args.cmd == 'form':
        print(json.dumps(form_payload(args.mode, args)))
    else:
        actions(args)


if __name__ == '__main__':
    main()
