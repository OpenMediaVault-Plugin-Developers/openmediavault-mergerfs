# @license   http://www.gnu.org/licenses/gpl.html GPL Version 3
# @author    OpenMediaVault Plugin Developers <plugins@omv-extras.org>
# @copyright Copyright (c) 2019-2022 OpenMediaVault Plugin Developers
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
{% set pooldiresc = salt['cmd.run']('systemd-escape --path ' ~ pooldir) %}
{% set shortdir = mountdir ~ '/mfs' %}

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

{% for pool in config.pools.pool | selectattr('enable') | rejectattr('fstab') %}
{% if pool.mntentref | length == 36 %}

{% set poolmount = salt['omv_conf.get']('conf.system.filesystem.mountpoint', pool.mntentref) -%}
{% set pooldir = poolmount.dir %}
{% set poolname = pool.name %}

{% set unitname = salt['cmd.run']('systemd-escape --path --suffix=mount ' ~ pooldir) %}
{% set mountunit =  mountsdir ~ "/" ~ unitname %}

configure_mergerfs_{{ poolname }}:
  file.managed:
    - name: {{ mountunit }}
    - source:
      - salt://{{ tpldir }}/files/etc-systemd-system-mergerfs_mount.j2
    - context:
        pool: {{ pool | json }}
    - template: jinja
    - user: root
    - group: root
    - mode: "0644"

systemd-reload_{{ poolname }}:
  cmd.run:
    - name: systemctl daemon-reload

enable_{{ poolname }}_mergerfs:
  service.enabled:
    - name: {{ unitname }}
    - enable: True

{% if not salt['mount.is_mounted'](pooldir) %}

restart_{{ poolname }}_mergerfs:
  cmd.run:
    - name: systemctl restart {{ unitname }}

{% endif %}

{% endif %}
{% endfor %}
