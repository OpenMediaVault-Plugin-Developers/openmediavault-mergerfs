<?php
/**
 * @license   http://www.gnu.org/licenses/gpl.html GPL Version 3
 * @author    Volker Theile <volker.theile@openmediavault.org>
 * @copyright Copyright (c) 2009-2013 Volker Theile
 * @copyright Copyright (c) 2013-2026 openmediavault plugin developers
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
        $this->registerMethod("getPoolPaths");
        $this->registerMethod("removePath");
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
            $pathList = array_filter(
                explode(':', $objectv->get("paths")),
                function($p) { return strlen($p) > 2; }
            );
            $objectv->add("pathcount", "integer", count($pathList));
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
        $this->restartPoolMount($mntobj->get('dir'));
    }

    private function isMounted($dir)
    {
        $cmd = new \OMV\System\Process('mountpoint', ['-q', escapeshellarg($dir)]);
        $cmd->setQuiet(true);
        $cmd->execute($output, $exitStatus);
        return 0 === $exitStatus;
    }

    private function restartPoolMount($dir)
    {
        // get escaped systemd mount
        $cmdArgs = [];
        $cmdArgs[] = '--path';
        $cmdArgs[] = '--suffix=mount';
        $cmdArgs[] = $dir;
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
                $allowed = ['balance', 'dedup'];
                if (!in_array($params['command'], $allowed, true)) {
                    throw new \OMV\Exception('Invalid command "%s".', $params['command']);
                }
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

    public function getPoolPaths($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, "rpc.common.objectuuid");
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $poolobj = $db->get("conf.service.mergerfs.pool", $params['uuid']);
        $result = [];
        foreach (explode(':', $poolobj->get('paths')) as $path) {
            if (strlen($path) > 2) {
                $result[] = ['path' => $path];
            }
        }
        return $result;
    }

    public function removePath($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // convert boolean string to boolean
        if (isset($params['deletesource'])) {
            $params['deletesource'] = filter_var($params['deletesource'], FILTER_VALIDATE_BOOLEAN);
        }
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, "rpc.mergerfs.removepath");
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $poolobj = $db->get("conf.service.mergerfs.pool", $params['uuid']);
        $mntobj = $db->get("conf.system.filesystem.mountpoint", $poolobj->get('mntentref'));
        $mntDir = $mntobj->get('dir');
        // Determine the current branch paths and the ones that remain after
        // the requested path is removed.
        $paths = array_values(array_filter(
            explode(':', $poolobj->get('paths')),
            function($p) { return strlen($p) > 2; }
        ));
        $removePath = $params['path'];
        if (!in_array($removePath, $paths, true)) {
            throw new \OMV\Exception(
                'The path "%s" is not part of this pool.', $removePath);
        }
        $remaining = array_values(array_diff($paths, [$removePath]));
        if (count($remaining) < 1) {
            throw new \OMV\Exception(
                'Refusing to remove the last remaining path of the pool.');
        }
        // Create the background process.
        return $this->execBgProc(function($bgStatusFilename, $bgOutputFilename)
            use ($params, $context, $poolobj, $db, $mntDir, $removePath, $remaining) {
                // Make sure the data on the branch being removed fits into the
                // free space of the remaining branches before changing anything.
                $usedBytes = 0;
                $cmd = new \OMV\System\Process('du', ['-sb', escapeshellarg($removePath)]);
                $cmd->setQuiet(true);
                $cmd->execute($output);
                if (isset($output[0])) {
                    $usedBytes = intval(strtok($output[0], "\t "));
                }
                $freeBytes = 0;
                foreach ($remaining as $branch) {
                    $avail = @disk_free_space($branch);
                    if (false !== $avail) {
                        $freeBytes += $avail;
                    }
                }
                if ($usedBytes > $freeBytes) {
                    throw new \OMV\Exception(
                        'Not enough free space on the remaining branches to '.
                        'migrate the data (need %d bytes, have %d bytes).',
                        $usedBytes, $freeBytes);
                }
                $poolobj->set('paths', implode(':', $remaining));
                $db->set($poolobj);
                $this->writeBgProcOutput($bgOutputFilename,
                    sprintf("Removing path '%s' from pool and applying changes ...\n",
                    $removePath));
                \OMV\Rpc\Rpc::call('Config', 'applyChanges', [
                    'modules' => ['mergerfs', 'monit'],
                    'force' => true
                ], $context);
                // Drop the branch from the live mount.
                $dropped = false;
                if ($this->isMounted($mntDir)) {
                    $cmd = new \OMV\System\Process('setfattr', [
                        '-n', 'user.mergerfs.branches',
                        '-v', escapeshellarg(sprintf('-%s', $removePath)),
                        escapeshellarg(sprintf('%s/.mergerfs', rtrim($mntDir, '/')))
                    ]);
                    $cmd->setQuiet(true);
                    $cmd->execute($output, $exitStatus);
                    if (0 === $exitStatus) {
                        $dropped = true;
                        $this->writeBgProcOutput($bgOutputFilename,
                            "Dropped branch from the live mount via the mergerfs ".
                            "runtime control (no remount).\n");
                    }
                }
                // Fallback: restart the mount unit so it picks up the new branch list
                if (!$dropped) {
                    $this->writeBgProcOutput($bgOutputFilename,
                        "Restarting pool mount to apply the branch removal ...\n");
                    $this->restartPoolMount($mntDir);
                    $mounted = false;
                    for ($i = 0; $i < 15; $i++) {
                        if ($this->isMounted($mntDir)) {
                            $mounted = true;
                            break;
                        }
                        sleep(1);
                    }
                    if (!$mounted) {
                        throw new \OMV\Exception(
                            'The pool mount "%s" did not become active after '.
                            'restart; aborting before data migration.', $mntDir);
                    }
                }
                // Copy the data from the removed branch into the pool mount so
                // mergerfs redistributes it across the remaining branches.
                $this->writeBgProcOutput($bgOutputFilename,
                    sprintf("Migrating data from '%s' into the pool ...\n", $removePath));
                $cmdArgs = [];
                $cmdArgs[] = 'rsync';
                $cmdArgs[] = '-aHAX';
                $cmdArgs[] = '--info=progress2';
                $cmdArgs[] = '-v';
                if ($params['deletesource']) {
                    $cmdArgs[] = '--remove-source-files';
                }
                $cmdArgs[] = '--exclude=aquota.group';
                $cmdArgs[] = '--exclude=aquota.user';
                $cmdArgs[] = '--exclude=snapraid.content';
                $cmdArgs[] = '--exclude=snapraid.parity';
                $cmdArgs[] = '--exclude=snapraid.*-parity';
                $cmdArgs[] = escapeshellarg(sprintf('%s/', rtrim($removePath, '/')));
                $cmdArgs[] = escapeshellarg(sprintf('%s/', rtrim($mntDir, '/')));
                $cmd = new \OMV\System\Process($cmdArgs);
                if (0 !== ($exitStatus = $this->exec($cmd->getCommandLine(), $output, $bgOutputFilename))) {
                    throw new \OMV\ExecException($cmd->getCommandLine(), $output, $exitStatus);
                }
                return $output;
            }
        );
    }
}
