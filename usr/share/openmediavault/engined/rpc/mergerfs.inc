<?php
/**
 * @license   http://www.gnu.org/licenses/gpl.html GPL Version 3
 * @author    Volker Theile <volker.theile@openmediavault.org>
 * @copyright Copyright (c) 2009-2013 Volker Theile
 * @copyright Copyright (c) 2013-2021 OpenMediaVault Plugin Developers
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <http://www.gnu.org/licenses/>.
 */
require_once("openmediavault/globals.inc");
require_once("openmediavault/functions.inc");

class OMVRpcServiceMergerfs extends \OMV\Rpc\ServiceAbstract
{
    public function getName()
    {
        return "Mergerfs";
    }

    public function initialize()
    {
        $this->registerMethod("getList");
        $this->registerMethod("get");
        $this->registerMethod("set");
        $this->registerMethod("delete");
    }

    public function getList($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, "rpc.common.getlist");
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $objects = $db->get("conf.service.mergerfs.pool");
        // Add additional pool informations.
        $objectsAssoc = [];
        foreach ($objects as $objectk => &$objectv) {
            $paths = str_replace([',',':', PHP_EOL], '<br />', $objectv->get("paths"));
            $objectv->add("pathsa", "string", $paths);
            $objectsAssoc[] = $objectv->getAssoc();
        }
        // Filter the result.
        return $this->applyFilter($objectsAssoc, $params['start'], $params['limit'],
            $params['sortfield'], $params['sortdir']);
    }

    public function get($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, "rpc.common.objectuuid");
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get("conf.service.mergerfs.pool", $params['uuid']);
        $paths = str_replace(':', PHP_EOL, $object->get("paths"));
        $object->set("paths", $paths);
        return $object->getAssoc();
    }

    public function set($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        //$this->validateMethodParams($params, "rpc.mergerfs.set");
        $ppaths = str_replace([',',':'], PHP_EOL, $params['paths']);
        $paths = explode(PHP_EOL, $ppaths);
        foreach ($params['sharedfolderrefs'] as $uuid) {
            if (is_uuid($uuid)) {
                $sfpath = \OMV\Rpc\Rpc::call("ShareMgmt", "getPath", ["uuid" => $uuid], $context);
                $paths[] = $sfpath;
            }
        }
        unset($params['paths']);
        unset($params['sharedfolderrefs']);
        // remove bad lines in paths
        foreach ($paths as $pathKey => &$path) {
            if (strlen($path) < 3) {
                unset($paths[$pathKey]);
            }
        }
        $pathsu = array_unique($paths);
        sort($pathsu);
        $params['paths'] = implode(':', $pathsu);
        if (strlen($params['paths']) > 256) {
            throw new \OMV\Exception(gettext("Total length of all paths is longer than the systemd limit of 256 characters."));
        }
        // Prepare the configuration object.
        $object = new \OMV\Config\ConfigObject("conf.service.mergerfs.pool");
        $object->setAssoc($params);
        // Set the configuration object.
        $isNew = $object->isNew();
        $db = \OMV\Config\Database::getInstance();
        if (TRUE === $isNew) {
            // Check uniqueness
            $db->assertIsUnique($object, "name");
            $db->assertIsUnique($object, "paths");
        }
        $db->set($object);
        // create mntent entry for new pools
        if (TRUE === $isNew) {
            $baseDir = \OMV\Environment::get("OMV_MOUNT_DIR");
            $result = \OMV\Rpc\Rpc::call('FsTab', 'set', [
                'uuid' => $object->get('mntentref'),
                'fsname' => $object->get('uuid'),
                'dir' => sprintf("%s/mergerfs/%s", $baseDir, $object->get('name')),
                'type' => 'fuse.mergerfs',
                'opts' => '',
                'freq' => 0,
                'passno' => 0,
                'hidden' => true,
            ], $context);
            // update uuid in config
            $object->set('mntentref', $result['uuid']);
            $db->set($object);
        }
        // Return the configuration object.
        return $object->getAssoc();
    }

    public function delete($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, "rpc.common.objectuuid");
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get("conf.service.mergerfs.pool", $params['uuid']);
        // Delete the configuration object.
        $db->delete($object);
        // Delete the filesystem
        \OMV\Rpc\Rpc::call("FsTab", "delete", [
            "uuid" => $object->get("mntentref")
        ], $context);
        // Return the deleted configuration object.
        return $object->getAssoc();
    }
}
