{% set config = salt['omv_conf.get']('conf.service.mergerfs') %}
{% set mountdir = salt['pillar.get']('default:OMV_MOUNT_DIR', '/srv') %}
{% for pool in config.pools.pool | selectattr('fstab') | selectattr('enable') %}
{% if pool.mntentref | length == 36 %}
{% set poolmount = salt['omv_conf.get']('conf.system.filesystem.mountpoint', pool.mntentref) -%}
{% set pooldir = poolmount.dir %}
{% set poolname = pool.name %}
{% set mntDir = poolmount.dir %}
{% set mount = True %}
{% if salt['mount.is_mounted'](mntDir) %}
{% set mount = False %}
{% endif %}
{% set options = [] %}
{% set _ = options.append('category.create=' ~ pool.createpolicy) %}
{% set _ = options.append('minfreespace=' ~ pool.minfreespace | string ~ pool.minfreespaceunit) %}
{% set _ = options.append('fsname=' ~ pool.name ~ ':' ~ pool.uuid) %}
{% for option in pool.options.split(',') %}
{% set _ = options.append(option) %}
{% endfor %}
{% set branches = [] %}
{% set branchDirs = pool.paths.split(':') %}
{% for dir in branchDirs %}
{% if dir | length > 2 %}
{% set _ = branches.append(dir) %}
{% set parent = salt['cmd.shell']('omv-findmnt "' ~ dir ~ '" | sort -u') %}
{% if parent | length > 1 %}
{% set reqs = parent.split(' ') %}
{% for req in reqs %}
{% if req | length > 1 %}
{% set _ = options.append('x-systemd.requires=' ~ req) %}
{% endif %}
{% endfor %}
{% endif %}
{% endif %}
{% endfor %}

create_mergerfs_fstab_mountpoint_{{ pool.mntentref }}:
  file.accumulated:
    - filename: "/etc/fstab"
    - text: "{{ branches | join(':') }}\t\t{{ mntDir }}\tfuse.mergerfs\t{{ options | join(',') }}\t0 0"
    - require_in:
      - file: append_fstab_entries

mount_filesystem_mountpoint_{{ pool.mntentref }}:
  mount.mounted:
    - name: {{ mntDir }}
    - device: {{ branches | join(':') }}
    - fstype: "fuse.mergerfs"
    - opts: {{ options }}
    - mkmnt: True
    - persist: False
    - mount: {{ mount }}

{% endif %}
{% endfor %}
