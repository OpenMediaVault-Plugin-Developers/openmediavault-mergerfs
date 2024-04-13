{% set notification_config = salt['omv_conf.get_by_filter'](
  'conf.system.notification.notification',
  {'operator': 'stringEquals', 'arg0': 'id', 'arg1': 'monitfilesystems'})[0] %}

{% if notification_config.enable | to_bool %}

{% set mountpoints = salt['omv_conf.get_by_filter'](
  'conf.system.filesystem.mountpoint',
  {"operator": "stringEquals", "arg0": "type", "arg1": "mergerfs"}) %}

configure_monit_mergerfs_service:
  file.managed:
    - name: "/etc/monit/conf.d/openmediavault-mergerfs.conf"
    - source:
      - salt://{{ tpldir }}/files/mergerfs.j2
    - template: jinja
    - context:
        mountpoints: {{ mountpoints | json }}
    - user: root
    - group: root
    - mode: 644

{% endif %}
