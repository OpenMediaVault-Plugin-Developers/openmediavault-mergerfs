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

namespace OMV\System\Filesystem;

class Mergerfs implements FilesystemInterface, SharedFolderCandidateInterface
{
    private $backend;
    private $label;
    private $mountPoint;
    private $type;
    private $usage = 'filesystem';
    private $uuid;

    public function __construct($uuid, $mountPoint, $label, \OMV\System\Filesystem\Backend\BackendAbstract $backend)
    {
        $this->backend = $backend;
        $this->label = $label;
        $this->mountPoint = $mountPoint;
        $this->type = $this->backend->getType();
        $this->uuid = $uuid;
    }

    public function exists()
    {
        return true;
    }

    public function getBackend()
    {
        return $this->backend;
    }

    public function getCanonicalDeviceFile()
    {
        return $this->getDeviceFile();
    }

    public function getDetails()
    {
        return '';
    }

    public function getDescription()
    {
        $statistics = $this->getStatistics();

        return sprintf(
            '%s [%s (%d%%) used, %s available]',
            $this->getLabel(),
            binary_format($statistics['used']),
            $statistics['percentage'],
            binary_format($statistics['available'])
        );
    }

    public function getDeviceFile()
    {
        return $this->mountPoint;
    }

    public function getDeviceName()
    {
        return $this->mountPoint;
    }

    public function getDeviceFileById()
    {
        return null;
    }

    public function getDeviceFileByLabel()
    {
        return null;
    }

    public function getDeviceFileByUuid()
    {
        return null;
    }

    public function getDeviceFiles()
    {
        return [$this->getPreferredDeviceFile()];
    }

    public function getDeviceFileSymlinks()
    {
        return [];
    }

    public function getLabel()
    {
        return !empty($this->label) ? $this->label : '';
    }

    public function getParentDeviceFile()
    {
        return false;
    }

    public function getPredictableDeviceFile()
    {
        return $this->getDeviceFile();
    }

    public function getPreferredDeviceFile()
    {
        return $this->getDeviceFile();
    }

    public function getSize()
    {
        return 0;
    }

    public function getStatistics()
    {
        $cmd = new \OMV\System\Process('df', '-PT', escapeshellarg($this->mountPoint));
        $cmd->setRedirect2to1();
        $cmd->execute($output);

        $result = false;

        foreach ($output as $line) {
            $matches = preg_split('/[\s,]+/', $line);

            if (0 !== strcasecmp($this->mountPoint, $matches[6])) {
                continue;
            }

            $result = [
                'devicefile' => $this->getDeviceFile(),
                'type' => $matches[1],
                'blocks' => $matches[2],
                'size' => bcmul($matches[2], '1024', 0),
                'used' => binary_convert($matches[3], 'KiB', 'B'),
                'available' => binary_convert($matches[4], 'KiB', 'B'),
                'percentage' => intval(trim($matches[5], '%')),
                'mountpoint' => $matches[6],
            ];
        }

        return $result;
    }

    public function getType()
    {
        return $this->type;
    }

    public function getUuid()
    {
        return !empty($this->uuid) ? $this->uuid : '';
    }

    public function grow()
    {
        throw new \OMV\Exception('Unsupported operation.');
    }

    public function hasDeviceFileById()
    {
        return false;
    }

    public function hasDeviceFileByLabel()
    {
        return false;
    }

    public function hasDeviceFileByUuid()
    {
        return false;
    }

    public function hasLabel()
    {
        return !empty($this->getLabel());
    }

    public function hasMultipleDevices()
    {
        return count($this->getDeviceFiles()) > 1;
    }

    public function hasUuid()
    {
        return !empty($this->getUuid());
    }

    public function remove()
    {
        throw new \OMV\Exception('Unsupported operation.');
    }

    public function isMounted()
    {
        $cmd = new \OMV\System\Process('findmnt', escapeshellarg($this->mountPoint));

        try {
            $cmd->execute();
        } catch (\OMV\ExecException $e) {
            return false;
        }

        return true;
    }

    public function mount($options = '')
    {
        $cmd = new \OMV\System\Process('mount', '-v', escapeshellarg($this->mountPoint));
        $cmd->setRedirect2to1();
        $cmd->execute();
    }

    public function shrink()
    {
        throw new \OMV\Exception('Unsupported operation.');
    }

    public function umount($force = false, $lazy = false, $directory = false)
    {
        $args = ['fusermount', '-u'];

        if ($lazy) {
            $args[] = '-z';
        }

        $args[] = escapeshellarg($this->mountPoint);

        $cmd = new \OMV\System\Process(...$args);
        $cmd->setRedirect2to1();
        $cmd->execute();
    }
}
