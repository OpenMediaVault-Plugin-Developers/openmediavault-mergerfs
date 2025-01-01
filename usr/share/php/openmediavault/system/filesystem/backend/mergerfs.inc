<?php

/**
 * Copyright (C) 2014-2025 openmediavault plugin developers.
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

use OMV\Config\Database;
use OMV\Exception;
use OMV\System\Filesystem\Union;
use OMV\System\Process;
use SplFileObject;

class Mergerfs extends UnionAbstract
{
    /**
     * @var string
     */
    private $mountPointDataModelPath = 'conf.system.filesystem.mountpoint';

    public function __construct(Database $database)
    {
        parent::__construct($database);

        $this->type = 'fuse.mergerfs';
        $this->properties = self::PROP_POSIX_ACL;
    }

    /**
     * @param string $args A string with either the UUID, mount point or the
     *                     fsname
     *
     * @return Union
     *
     * @throws Exception
     */
    public function getImpl($args)
    {
        $uuid = $args;

        if (!is_uuid($args)) {
            // Assume we got the mount directory.
            $mountPoint = $args;

            // Check if it's the real fsname and handle it (the real fsname
            // contains ':' to separate the branches).
            if (strpos($args, ':') !== false) {
                $mountPoint = self::fetchMountPointFromFstabByFsnameAndType($args, $this->type);
            }

            $uuid = self::extractUuidFromMountPoint($mountPoint);
        }

        $object = $this->database->get($this->dataModelPath, $uuid);
        $mountPointObject = $this->database->get($this->mountPointDataModelPath, $object->get('mntentref'));

        return new Union($object->get('uuid'), $mountPointObject->get('dir'), $object->get('name'), $this);
    }

    /**
     * Extract the UUID of a mount by it's mount point.
     *
     * @param string $mountPoint
     *
     * @return string
     *
     * @throws Exception
     */
    public static function extractUuidFromMountPoint($mountPoint)
    {
        $regex = '/[a-f0-9]{8}\-[a-f0-9]{4}\-4[a-f0-9]{3}\-(8|9|a|b)[a-f0-9]{3}\-[a-f0-9]{12}/';
        $mountsFile = '/proc/mounts';

        foreach (new SplFileObject($mountsFile) as $content) {
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
            $args = sprintf('systemctl cat "%s" | awk -F":" \'/What/ { print $2 }\'', $mountPoint);
            $cmd = new Process($args);
            $cmd->execute($output);
            $uuid = $output[0];
        }
        if (!is_uuid($uuid)) {
            throw new Exception(sprintf(
                'Couldn\'t extract an UUID from the provided path \'%s\'.',
                $mountPoint
            ));
        }

        return $uuid;
    }

    /**
     * Fetch the mount point from either '/etc/fstab' or '/proc/mounts'.
     *
     * @param string $fsname
     * @param string $type
     *
     * @return string
     *
     * @throws Exception
     */
    private static function fetchMountPointFromFstabByFsnameAndType($fsname, $type)
    {
        $mountsFile = '/proc/mounts';

        foreach (new SplFileObject($mountsFile) as $content) {
            $splitContent = preg_split('/\s+/', $content);

            if ($fsname === $splitContent[0] && $type === $splitContent[2]) {
                return $splitContent[1];
            }
            if ($type === $splitContent[2]) {
                return $fsname;
            }
        }

        throw new Exception(sprintf(
            'Could not fetch a matching mount point from the provided fsname: \'%s\'.',
            $fsname
        ));
    }

    public function isBlkidEnumerated()
    {
        return FALSE;
    }
}
