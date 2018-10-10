package PVE::Storage::3parPlugin;

use strict;
use warnings;
use IO::File;
use Net::IP;
use File::Path;
use File::Basename;
use PVE::Tools qw(run_command);
use PVE::ProcFSTools;
use PVE::Storage::Plugin;
use PVE::JSONSchema qw(get_standard_option);

use base qw(PVE::Storage::Plugin);



sub api {
    return 1;
}

sub type {
    # Fake the type as a compatible plugin, so that container creation works
    return 'drbd';
}

# Configuration

sub plugindata {
    return {
        content => [ {images => 1, rootdir => 1}, { images => 1, rootdir => 1 }],
    };
}

sub properties {
    return {
        cpg => {
            description => "Common Provisioning Group (CPG) name",
            type => 'string',
        },
        user => {
            description => "Volume group name.",
            type => 'string',
        },
        address => {
            description => "Volume group name.",
            type => 'string',
        },
        cluster_identifier => {
            description => "Volume group name.",
            type => 'string',
        },
        snapshot_expiry => {
            description => "Volume group name.",
            type => 'string',
        },
        host => {
            description => "Volume group name.",
            type => 'string',
        },
        startvlun => {
            description => "Volume group name.",
            type => 'integer',
        },
        use_dedup => {
            description => "Volume group name.",
            type => 'boolean',
        },
        use_thin => {
            description => "Volume group name.",
            type => 'boolean',
        },
        use_compr => {
            description => "Volume group name.",
            type => 'boolean',
        },
        snapshot_expiry => {
            description => "Volume group name.",
            type => 'string',
        },
    };
}

sub options {
    return {
        cpg                => { fixed    => 1 },
        user               => { fixed    => 1 },
        address            => { fixed    => 1 },
        cluster_identifier => { fixed    => 1 },
        snapshot_expiry    => { optional => 1 },
        host               => { fixed    => 1 },
        startvlun          => { fixed    => 1 },
        use_dedup          => { fixed    => 1 },
        use_thin           => { fixed    => 1 },
        use_compr          => { fixed    => 1 },
    };
}

sub register {
    my ($class) = @_;

    # Make no duplicate checks: we overwrite DRBD module
    my $type = $class->type();
    my $pdata = $class->private();
    my $plugindata = $class->plugindata();
    $pdata->{plugindata}->{$type} = $plugindata;
    $pdata->{plugins}->{$type} = $class;
}

sub volume_status {
    my ($class, $scfg, $name) = @_;

    my $cmd = ['/usr/bin/ssh', $scfg->{user} . '@' . $scfg->{address}, 'showvlun', '-t', '-showcols',
        'VVName,Lun,HostName,VV_WWN', '-v', $name];
    my $correct = undef;

    run_command($cmd, errmsg => "unable to read vlun information from 3par\n", outfunc => sub {
        my $line = shift;
        my ($vv, $lun, $host, $wwid) = split ' ', $line;

        return if !$vv || !$lun || !$host || !$wwid;
        return if $lun !~ m/\d+/;

        $correct = { 'vv' => $vv, 'lun' => $lun, 'wwid' => $wwid } if $host eq $scfg->{host};
    });

    #die "no wwid found for volume\n" if !$correct;

    return $correct;
}

sub volume_name {
    my ($class, $scfg, $volname, $snapname) = @_;

    return $scfg->{cluster_identifier} . "_" . $volname . ($snapname ? "_$snapname" : "");
}

sub parse_volname {
    my ($class, $volname) = @_;

    if ($volname =~ m/^((vm|base)-(\d+)-\S+)$/) {
        return ('images', $1, $3, undef, undef, $2 eq 'base', 'raw');
    }

    die "unable to parse volume name '$volname'\n";
}

sub filesystem_path {
    my ($class, $scfg, $volname, $snapname) = @_;
    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    $class->activate_volume(undef, $scfg, $volname, $snapname);

    my $volume_status = $class->volume_status($scfg, $class->volume_name($scfg, $volname, $snapname));
    my $path = "/dev/mapper/3" . lc $volume_status->{wwid} if $volume_status;


=pod
    my @glob = glob("/sys/class/block/dm-*/slaves/sd?/device/wwid");
    my $path = undef;

    foreach my $file (@glob) {
        open my $fh, "<", $file or die "unable to open wwid file\n";
        my $line = <$fh>;
        close $fh;
        if ($volume_status && $volume_status->{wwid} =~ m/$line/) {
            $path = "/dev/$1" if $file =~ m#^/sys/class/block/(dm-\d+)#;
            last;
        }
    }
=cut

    return wantarray ? ($path, $vmid, $vtype) : $path;
}

sub create_base {
    my ($class, $storeid, $scfg, $volname) = @_;

    die "Not implemented\n";
}

sub clone_image {
    my ($class, $scfg, $storeid, $volname, $vmid, $snap) = @_;

    die "Not implemented\n";
}

sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;
}

sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    my $cmd = ['/usr/bin/ssh', $scfg->{user} . '@' . $scfg->{address}, 'createvlun', '-novcn', '-f',
        $class->volume_name($scfg, $volname, $snapname), $scfg->{startvlun} . "+", $scfg->{host}];
    my $volume_status = $class->volume_status($scfg, $class->volume_name($scfg, $volname, $snapname));

    run_command($cmd, errmsg => "failure creating vlun\n")
        if !$volume_status;

    $volume_status = $class->volume_status($scfg, $class->volume_name($scfg, $volname, $snapname));

    my @glob = glob("/sys/class/scsi_host/host*/scan");

    foreach my $file (@glob) {
        $file = $1 if $file =~ m/^(.+)$/;
        open(my $fh, ">", $file) or die "unable to open SCSI scan file\n";
        print $fh "- - " . $volume_status->{lun};
        close $fh;
    }

    $cmd = ['/sbin/multipath', '-r', "3" . lc $volume_status->{wwid}];

    run_command($cmd, errmsg => "failure scanning for multipath devices\n");
}

sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    my $volume_status = $class->volume_status($scfg, $class->volume_name($scfg, $volname, $snapname));

    die "vlun for $volname not found. please perform cleanup manually\n" if !$volume_status;

    my @glob = glob("/sys/class/scsi_disk/*/device/wwid");
    my $files = [];

    foreach my $file (@glob) {
        $file = $1 if $file =~ m/^(.+)$/;
        open(my $fh, "<", $file) or die "unable to open wwid file $file\n";
        my $line = <$fh>;
        push @$files, $file if (index(lc $line, lc $volume_status->{wwid}) != -1);
        close $fh;
    }

    my $cmd = ['/sbin/multipath', '-f', "3" . lc $volume_status->{wwid}];

    run_command($cmd, errmsg => "unable to remove volume from multipath\n");

    foreach my $file (@$files) {
        my $delete = "$1/delete" if $file =~ m/(\/sys\/class\/scsi_disk\/.+\/device)\/wwid/;
        die "no file found or malformed file\n" if !$delete;
        open(my $fh, ">", $delete);
        print $fh "1" or die "unable to write to scsi delete file in sysfs $delete\n";
        close $fh;
    }

    $cmd = ['/usr/bin/ssh', $scfg->{user} . '@' . $scfg->{address}, 'removevlun', '-f',
        $class->volume_name($scfg, $volname, $snapname), $volume_status->{lun}, $scfg->{host}];

    run_command($cmd, errmsg => "unable to remove virtual lun\n");
}

sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;
    $name = "vm-$vmid-disk-1" if !$name;

    die "unsupported format '$fmt'" if $fmt ne 'raw';
    die "illegal name '$name' - should be 'vm-$vmid-*'\n" if $name !~ m/^vm-$vmid-/;

    my $cmd = ['/usr/bin/ssh', $scfg->{user} . '@' . $scfg->{address}, 'createvv'];

    push @$cmd, '-compr' if $scfg->{use_compr};
    push @$cmd, '-tdvv' if $scfg->{use_dedup};
    push @$cmd, '-tpvv' if $scfg->{use_thin} && !$scfg->{use_dedup};
    push @$cmd, '-snp_cpg', $scfg->{cpg}, $scfg->{cpg}, $class->volume_name($scfg, $name), $size / 1024 / 1024 . "g";

    run_command($cmd, errmsg => "failure creating virtual volume\n");

    return $name;
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase) = @_;

    $class->deactivate_volume($storeid, $scfg, $volname)
        if $class->volume_status($scfg, $class->volume_name($scfg, $volname));

    my $cmd = ['/usr/bin/ssh', $scfg->{user} . '@' . $scfg->{address}, 'removevv', '-f',
        $class->volume_name($scfg, $volname)];

    run_command($cmd, errmsg => "unable to remove virtual volume\n");
}

sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;

    my $cmd = ['/usr/bin/ssh', $scfg->{user} . '@' . $scfg->{address}, 'showvv', '-notree' ,'-p', '-cpg', $scfg->{cpg}];
    my $res = [];

    run_command($cmd, outfunc => sub {
        my $line = shift;
        my (undef, $identifier, undef, undef, undef, undef, undef, undef, undef, undef, undef, $size) = split ' ', $line;

        return if !$identifier || !$size;

        my ($cluster, $name) = split '_', $identifier;

        return if !$name || !$cluster;

        return if $name !~ m/^vm-(\d+)-/;
        my $owner = $1;
        return if $size !~ m/^\d+$/;
        return if $cluster ne $scfg->{cluster_identifier};

        my $volid = "$storeid:$name";

        if($vollist) {
            my $found = grep { $_ eq $volid } @$vollist;
            return if !$found;
        } else {
            return if defined($vmid) && ($owner ne $vmid);
        }

        push @$res, { volid => $volid, format => 'raw', size => $size * 1024 * 1024, vmid => $owner };
    });

    return $res;
}

sub status {
    my ($class, $storeid, $scfg, $cache) = @_;

    my $cmd = ['/usr/bin/ssh', $scfg->{user} . '@' . $scfg->{address}, 'showsys', '-space'];
    my $free = 0;
    my $total = 0;

    run_command($cmd, outfunc => sub {
        my $line = shift;
        $total = $1 * 1024 * 1024 if $line =~ m/^Total Capacity\s+:\s+(\d+)/;
        $free = $1 * 1024 * 1024 if $line =~ m/^\s+Free\s+:\s+(\d+)/;
    }, errmsg => "unable to showsys\n");

    return ($total, $free, $total - $free, 1);
}

sub volume_resize {
    my ($class, $scfg, $storeid, $volname, $size, $running) = @_;

    my $cur = grep { $_->{volid} eq $volname } $class->list_images($storeid, $scfg);

    die "cannot shrink volume\n" if $size < $cur->{size};

    my $cmd = ['/usr/bin/ssh', $scfg->{user} . '@' . $scfg->{address}, 'growvv', '-f',
        $scfg->{cluster_identifier} . "_" . $volname, $size - $cur->{size}];

    run_command($cmd, errmsg => "error resizing volume\n");

    return 1;
}

sub volume_snapshot {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    my $vv = $scfg->{cluster_identifier} . "_" . $volname;
    my $cmd = ['/usr/bin/ssh', $scfg->{user} . '@' . $scfg->{address}, 'createsv', '-ro'];
    push @$cmd, '-exp', $scfg->{snapshot_expiry} if $scfg->{snapshot_expiry};
    push @$cmd, "${vv}_{$snap}", $vv;

    run_command($cmd, errmsg => "unable to create snapshot of virtual volume");
}

sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    my $vv = $scfg->{cluster_identifier} . "_${volname}_{$snap}";
    my $cmd = ['/usr/bin/ssh', $scfg->{user} . '@' . $scfg->{address}, 'promotesv', $vv];

    run_command($cmd, errmsg => "unable to rollback snapshot");
}

sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    $class->free_image($storeid, $scfg, "${volname}_{$snap}");
}

sub volume_export_formats {
    my ($class, $scfg, $storeid, $volname, $snapshot, $base_snapshot, $with_snapshots) = @_;

    die "Not implemented\n";
}

sub volume_export {
    my ($class, $scfg, $storeid, $fh, $volname, $format, $snapshot, $base_snapshot, $with_snapshots) = @_;

    die "volume export format $format not available for $class\n"
        if $format ne 'raw+size';
    die "cannot export volumes together with their snapshots in $class\n"
        if $with_snapshots;
    die "cannot export a snapshot in $class\n" if defined($snapshot);
    die "cannot export an incremental stream in $class\n" if defined($base_snapshot);
    my $file = $class->path($scfg, $volname, $storeid);
    my $size;
    # should be faster than querying LVM, also checks for the device file's availability
    run_command(['/sbin/blockdev', '--getsize64', $file], outfunc => sub {
        my ($line) = @_;
        die "unexpected output from /sbin/blockdev: $line\n" if $line !~ /^(\d+)$/;
        $size = int($1);
    });
    PVE::Storage::Plugin::write_common_header($fh, $size);
    run_command(['dd', "if=$file", "bs=64k"], output => '>&'.fileno($fh));
}

sub volume_import {
    my ($class, $scfg, $storeid, $fh, $volname, $format, $base_snapshot, $with_snapshots) = @_;

    die "Not implemented\n";
}

1;