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

abstract class UnionAbstract extends BackendAbstract
{
    /**
     * @var Database
     */
    protected $database;

    /**
     * @var string
     */
    protected $dataModelPath = 'conf.service.mergerfs.pool';

    public function __construct(Database $database)
    {
        $this->database = $database;
    }

    /**
     * Get a list of filesystems of the given filesystem backend.
     *
     * @return array
     */
    public function enumerate()
    {
        $filesystems = [];
        $objects = [];

        try {
            $objects = $this->database->get($this->dataModelPath);
        } catch (Exception $e) {
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

    /**
     * Check whether the filesystem implemented by this backend is identified by
     * the block device identification library. If this is not the case, then
     * the backend must override the enumerate method.
     *
     * @return bool
     */
    public function isBlkidEnumerated()
    {
        return false;
    }

    /**
     * Check whether the given filesystem identifier is represented by this
     * filesystem backend.
     *
     * @param string $id The filesystem identifier (e.g. UUID or device path)
     *
     * @return bool
     */
    public function isTypeOf($id)
    {
        foreach ($this->enumerate() as $mount) {
            if ($mount['uuid'] == $id || $mount['devicefile'] == $id) {
                return true;
            }
        }

        return false;
    }

    /**
     * Does the filesystem have a device file? E.g. union mount or overlay
     * filesystems like Mergerfs don't have a device file.
     *
     * @return bool
     */
    public function hasDeviceFile()
    {
        return false;
    }

    /**
     * Get the object of the class that represents and implements a filesystem
     * of this filesystem backend.
     *
     * @param array $args
     *
     * @return \OMV\System\Filesystem\Union
     */
    public function getImpl($args)
    {
        // BackendAbstract is already implementing this method so we can't mark
        // it as abstract.
        throw Exception('Unimplemented method. Implement this in the derived class.');
    }
}
