<?php
/**
 * @license   http://www.gnu.org/licenses/gpl.html GPL Version 3
 * @author    Volker Theile <volker.theile@openmediavault.org>
 * @copyright Copyright (c) 2009-2013 Volker Theile
 * @copyright Copyright (c) 2013-2023 OpenMediaVault Plugin Developers
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

        $this->registerMethod("restartPool");
        $this->registerMethod("toolsCommand");
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
            $mntentref = $objectv->get("mntentref");
	        $sfobjects = $db->get("conf.system.sharedfolder");
            $inuse = false;
            foreach ($sfobjects as $sfobject) {
                $sfmntentref = $sfobject->get("mntentref");
                if ($mntentref == $sfmntentref) {
                    $inuse = true;
                    break;
                }
            }
            $objectv->add("inuse", "boolean", $inuse);
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
        $ro = false;
        if (strlen($object->get("name")) > 0) {
            $ro = true;
        }
        $object->add("namero", "boolean", $ro);
        return $object->getAssoc();
    }

    public function set($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        $db = \OMV\Config\Database::getInstance();
        $ppaths = str_replace([',',':'], PHP_EOL, $params['paths']);
        $paths = explode(PHP_EOL, $ppaths);
        foreach ($params['sharedfolderrefs'] as $uuid) {
            if (is_uuid($uuid)) {
                $sfpath = \OMV\Rpc\Rpc::call("ShareMgmt", "getPath", ["uuid" => $uuid], $context);
                $paths[] = $sfpath;
            }
        }
        foreach ($params['filesystems'] as $uuid) {
            if (is_uuid($uuid)) {
                $fsObject = $db->get("conf.system.filesystem.mountpoint", $uuid);
                $fspath = $fsObject->get("dir");
                $paths[] = $fspath;
            }
        }
        unset($params['filesystems']);
        unset($params['paths']);
        unset($params['sharedfolderrefs']);
        // remove bad lines in paths
        foreach ($paths as $pathKey => &$path) {
            if (strlen($path) < 3) {
                unset($paths[$pathKey]);
            }
        }
        $pathsu = array_unique($paths);
        $params['paths'] = implode(':', $pathsu);
        // trim whitespace from each option and remove noop options
        $options = explode(',', $params['options']);
        $optionst = array_map('trim', $options);
        $optremove = ['nonempty','use_ino','allow_other'];
        $optionsd = array_diff($optionst, $optremove);
        // remove create policy if found
        $optionsc = preg_grep("/^category.create=[a-zA-Z]+$/i", $optionsd, PREG_GREP_INVERT);
        // implode on comma back to string
        $params['options'] = implode(',', $optionsc);
        // Prepare the configuration object.
        $object = new \OMV\Config\ConfigObject("conf.service.mergerfs.pool");
        $object->setAssoc($params);
        // Set the configuration object.
        $isNew = $object->isNew();
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

    public function restartPool($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $poolobj = $db->get("conf.service.mergerfs.pool", $params['uuid']);
        $mntobj = $db->get("conf.system.filesystem.mountpoint", $poolobj->get('mntentref'));
        // get escaped systemd mount
        $cmdArgs = [];
        $cmdArgs[] = '--path';
        $cmdArgs[] = '--suffix=mount';
        $cmdArgs[] = $mntobj->get('dir');
        $output = [];
        $cmd = new \OMV\System\Process('systemd-escape', $cmdArgs);
        $cmd->execute($output, $exitStatus);
        // restart systemd mount
        $cmdArgs = [];
        $cmdArgs[] = 'restart';
        $cmdArgs[] = $output[0];
        $output = [];
        $cmd = new \OMV\System\Process('systemctl', $cmdArgs);
        $cmd->execute($output, $exitStatus);
    }

    public function toolsCommand($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $poolobj = $db->get("conf.service.mergerfs.pool", $params['uuid']);
        $mntobj = $db->get("conf.system.filesystem.mountpoint", $poolobj->get('mntentref'));
        // Create the background process.
        return $this->execBgProc(function($bgStatusFilename, $bgOutputFilename)
            use ($params, $mntobj) {
                $cmdArgs = [];
                $cmdArgs[] = sprintf('mergerfs.%s', $params['command']);
                $cmdArgs[] = "--exclude aquota.group";
                $cmdArgs[] = "--exclude aquota.user";
                $cmdArgs[] = "--exclude snapraid.content";
                $cmdArgs[] = "--exclude snapraid.parity";
                $cmdArgs[] = "--exclude snapraid.2-parity";
                $cmdArgs[] = "--exclude snapraid.3-parity";
                $cmdArgs[] = "--exclude snapraid.4-parity";
                $cmdArgs[] = "--exclude snapraid.5-parity";
                $cmdArgs[] = "--exclude snapraid.6-parity";
                switch($params['command']) {
                    case 'dedup':
                        if (!$params['practice']) {
                            $cmdArgs[] = "--execute";
                        }
                        $cmdArgs[] = "-vv";
                        $cmdArgs[] = sprintf('--dedup=%s', $params['dedup']);
                        break;
                    case 'balance':
                        break;
                }
                $cmdArgs[] = $mntobj->get('dir');
                $cmd = new \OMV\System\Process($cmdArgs);
                if (0 !== ($exitStatus = $this->exec($cmd->getCommandLine(), $output, $bgOutputFilename))) {
                    throw new \OMV\ExecException($cmd->getCommandLine(), $output, $exitStatus);
                }
                return $output;
            }
        );
    }
}
