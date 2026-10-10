# @license   http://www.gnu.org/licenses/gpl.html GPL Version 3
# @author    OpenMediaVault Plugin Developers <plugins@omv-extras.org>
# @copyright Copyright (c) 2019-2026 openmediavault plugin developers
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

{% set config = salt['omv_conf.get']('conf.service.mergerfs') %}
{% set mountsdir = '/etc/systemd/system' %}
{% set symlinksdir = mountsdir ~ '/multi-user.target.wants' %}
{% set mountdir = salt['pillar.get']('default:OMV_MOUNT_DIR', '/srv') %}
{% set pooldir = mountdir ~ '/mergerfs' %}
{% set pooldiresc = salt['cmd.run']("systemd-escape --path '" ~ pooldir ~ "'") %}

configure_pool_dir:
  file.directory:
    - name: "{{ pooldir }}"
    - makedirs: True

remove_mergerfs_mount_files_{{ mountsdir }}:
  module.run:
    - file.find:
      - path: "{{ mountsdir }}"
      - iname: "{{ pooldiresc }}-*.mount"
      - delete: "f"

systemd_remove_dead_symlinks:
  cmd.run:
    - name: find "{{ symlinksdir }}" -name "{{ pooldiresc }}-*.mount" -xtype l -print -delete

{#- Collect the pools that have a valid mount point entry. #}
{%- set pools = [] %}
{%- for pool in config.pools.pool %}
{%- if pool.mntentref | length == 36 %}
{%- set poolmounts = salt['omv_conf.get_by_filter'](
  'conf.system.filesystem.mountpoint',
  {'operator': 'stringEquals', 'arg0': 'uuid', 'arg1': pool.mntentref}) %}
{%- if poolmounts | length > 0 %}
{%- set _ = pools.append({
  'pool': pool,
  'dir': poolmounts[0].dir,
  'unit': salt['cmd.run']("systemd-escape --path --suffix=mount '" ~ poolmounts[0].dir ~ "'")
}) %}
{%- endif %}
{%- endif %}
{%- endfor %}

{% for entry in pools %}
{% set poolname = entry.pool.name %}

configure_mergerfs_{{ poolname }}:
  file.managed:
    # Single quotes: YAML would turn the \x2d escapes into dashes otherwise.
    - name: '{{ mountsdir }}/{{ entry.unit }}'
    - source:
      - salt://{{ tpldir }}/files/etc-systemd-system-mergerfs_mount.j2
    - context:
        pool: {{ entry.pool | json }}
        mntdir: {{ entry.dir | json }}
    - template: jinja
    - user: root
    - group: root
    - mode: '0644'

{% endfor %}

# Always reload, also when the last pool was deleted and its unit removed.
mergerfs_systemd_reload:
  cmd.run:
    - name: systemctl daemon-reload

# Unmount pools that no longer exist in the configuration.
unmount_deleted_mergerfs_pools:
  cmd.run:
    - name: |
        findmnt -rn -t fuse.mergerfs -o TARGET | while read -r target; do
          case "${target}" in
            "{{ pooldir }}"/*) ;;
            *) continue ;;
          esac
          case " {{ pools | map(attribute='dir') | join(' ') }} " in
            *" ${target} "*) continue ;;
          esac
          umount "${target}" || echo "Failed to unmount deleted pool ${target}" >&2
        done

{% for entry in pools %}
{% set poolname = entry.pool.name %}

enable_{{ poolname }}_mergerfs:
  service.enabled:
    - name: {{ entry.unit }}
    - enable: True

{% if not salt['mount.is_mounted'](entry.dir) %}

restart_{{ poolname }}_mergerfs:
  cmd.run:
    - name: systemctl restart '{{ entry.unit }}'

{% endif %}

{% endfor %}
