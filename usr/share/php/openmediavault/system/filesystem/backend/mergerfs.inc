<?php

/**
 * Copyright (C) 2014-2026 openmediavault plugin developers.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

namespace OMV\System\Filesystem\Backend;

class Mergerfs extends BackendAbstract
{
    protected $database;

    private $dataModelPath = 'conf.service.mergerfs.pool';
    private $mountPointDataModelPath = 'conf.system.filesystem.mountpoint';

    public function __construct(\OMV\Config\Database $database)
    {
        $this->database = $database;
        $this->type = 'fuse.mergerfs';
        $this->properties = self::PROP_POSIX_ACL;
    }

    public function enumerate()
    {
        $filesystems = [];
        $objects = [];

        try {
            $objects = $this->database->get($this->dataModelPath);
        } catch (\OMV\Exception $e) {
            $objects = [];
        }
        foreach ($objects as $object) {
            $filesystem = $this->getImpl($object->get('uuid'));

            $filesystems[$filesystem->getDeviceFile()] = [
                'devicefile' => $filesystem->getDeviceFile(),
                'uuid' => $filesystem->getUuid(),
                'label' => $filesystem->getLabel(),
                'type' => $filesystem->getType(),
            ];
        }

        return $filesystems;
    }

    public function isBlkidEnumerated()
    {
        return false;
    }

    public function isTypeOf($id)
    {
        foreach ($this->enumerate() as $mount) {
            if ($mount['uuid'] == $id || $mount['devicefile'] == $id) {
                return true;
            }
        }

        return false;
    }

    public function hasDeviceFile()
    {
        return false;
    }

    public function getImpl($args)
    {
        $uuid = $args;

        if (!is_uuid($args)) {
            // Assume we got the mount directory.
            $mountPoint = $args;

            // If it's an fsname (contains ':' separating branches), resolve
            // it to the actual mount point via /proc/mounts.
            if (strpos($args, ':') !== false) {
                $mountPoint = null;
                foreach (new \SplFileObject('/proc/mounts') as $content) {
                    $splitContent = preg_split('/\s+/', $content);
                    if ($args === $splitContent[0] && $this->type === $splitContent[2]) {
                        $mountPoint = $splitContent[1];
                        break;
                    }
                }
                if ($mountPoint === null) {
                    throw new \OMV\Exception(sprintf(
                        'Could not fetch a matching mount point from the provided fsname: \'%s\'.',
                        $args
                    ));
                }
            }

            $uuid = self::extractUuidFromMountPoint($mountPoint);
        }

        $object = $this->database->get($this->dataModelPath, $uuid);
        $mountPointObject = $this->database->get($this->mountPointDataModelPath, $object->get('mntentref'));

        return new \OMV\System\Filesystem\Mergerfs($object->get('uuid'), $mountPointObject->get('dir'), $object->get('name'), $this);
    }

    public static function extractUuidFromMountPoint($mountPoint)
    {
        $regex = '/[a-f0-9]{8}\-[a-f0-9]{4}\-4[a-f0-9]{3}\-(8|9|a|b)[a-f0-9]{3}\-[a-f0-9]{12}/';
        $uuid = '';

        foreach (new \SplFileObject('/proc/mounts') as $content) {
            $splitContent = preg_split('/\s+/', $content);
            if (in_array($mountPoint, $splitContent)) {
                preg_match($regex, $content, $match);
                if ($match) {
                    $uuid = $match[0];
                    break;
                }
            }
        }
        if (!is_uuid($uuid)) {
            $shellCmd = sprintf('systemctl cat "%s" | awk -F":" \'/What/ { print $2 }\'', $mountPoint);
            $cmd = new \OMV\System\Process($shellCmd);
            $cmd->execute($output);
            $uuid = $output[0];
        }
        if (!is_uuid($uuid)) {
            throw new \OMV\Exception(sprintf(
                'Couldn\'t extract an UUID from the provided path \'%s\'.',
                $mountPoint
            ));
        }

        return $uuid;
    }
}
