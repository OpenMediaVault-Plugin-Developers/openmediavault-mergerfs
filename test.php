<?php

$test = "/zfstestpool1/ds1:/zfstestpool1/rrrwwwr		/srv/mergerfs/zfspooltestm1	fuse.mergerfs	category.create=epmfs,minfreespace=4G,fsname=zfspooltestm1:c1ef2bb6-1d42-4ca0-84d5-75dd6bd5c56d,defaults,allow_other,cache.files=off,use_ino,x-systemd.requires=/zfstestpool1/ds1,x-systemd.requires=/zfstestpool1/rrrwwwr	0 0";
//echo $test;
$regex = '/[a-f0-9]{8}\-[a-f0-9]{4}\-4[a-f0-9]{3}\-(8|9|a|b)[a-f0-9]{3}\-[a-f0-9]{12}/';
preg_match($regex, $test, $m);
if ($m) echo $m[0];

?>
