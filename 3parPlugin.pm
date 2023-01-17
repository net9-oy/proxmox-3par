package PVE::Storage::Custom::3parPlugin;

use strict;
use warnings;
use IO::File;
use Net::IP;
use File::Path;
use File::Basename;
use Sys::Hostname;
use PVE::Tools qw(run_command);
use PVE::ProcFSTools;
use PVE::Storage::Plugin;
use PVE::JSONSchema qw(get_standard_option);
use Time::HiRes qw(usleep nanosleep);
use POSIX;

use base qw(PVE::Storage::Plugin);

my $id_rsa_path = '/etc/pve/priv/3par/';

sub api {
    return 10;
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
        vname_prefix => {
            description => "VV prefix name",
            type => 'string',
        },
        user => {
            description => "SSH user for 3par",
            type => 'string',
        },
        address => {
            description => "IP address or hostname for 3par",
            type => 'string',
        },
        snapshot_expiry => {
            description => "Expiry of snapshots in 3par specified unit format",
            type => 'string',
        },
        startvlun => {
            description => "VLUN numbering starting value",
            type => 'integer',
        },
        use_dedup => {
            description => "Toggle deduplication on or off",
            type => 'boolean',
        },
        use_thin => {
            description => "Toggle thin provisioning on or off",
            type => 'boolean',
        },
        use_compr => {
            description => "Toggle compression on or off",
            type => 'boolean',
        },
    };
}

sub options {
    return {
        cpg                => { fixed    => 1 },
        vname_prefix       => { fixed    => 1 },
        user               => { fixed    => 1 },
        address            => { fixed    => 1 },
        snapshot_expiry    => { optional => 1 },
        startvlun          => { fixed    => 1 },
        use_dedup          => { fixed    => 1 },
        use_thin           => { fixed    => 1 },
        use_compr          => { fixed    => 1 },
    };
}

sub volume_status {
    my ($class, $scfg, $name) = @_;

    my $cmd = ['/usr/bin/ssh','-i', $id_rsa_path . $scfg->{address}.'_id_rsa', $scfg->{user} . '@' . $scfg->{address}, 'showvlun', '-t', '-showcols',
        'VVName,Lun,HostName,VV_WWN', '-v', $name];
    my $correct = undef;

    run_command($cmd, errmsg => "unable to read vlun information from 3par\n", outfunc => sub {
        my $line = shift;
        my ($vv, $lun, $host, $wwid) = split ' ', $line;

        return if !$vv || !$lun || !$host || !$wwid;
        return if $vv ne $name;
	($lun) = ($lun =~ /^(\d+)$/) or die "lun '$lun' not an integer\n"; # untaint
	$lun = int($lun);

        $correct = { 'vv' => $vv, 'lun' => $lun, 'wwid' => $wwid } if $host eq hostname();
        #print "Volume status " . $vv . " lun " . $lun . " WWID " . $wwid . "\n";
    });
    return $correct;
}

sub volume_name {
    my ($class, $vname_prefix, $volname, $snapname) = @_;

    return $vname_prefix . $volname . ($snapname ? "_$snapname" : "");
}

sub rescan_vol {
    my ($class, $scfg, $volname, $snapname) = @_;

    # We return and don't give an error, as the volume is not activated (and will be scanned when activated)
    my $volume_status = $class->volume_status($scfg, $class->volume_name($scfg->{vname_prefix}, $volname, $snapname))
        or return;

    my @glob = glob("/sys/class/block/dm-*/slaves/sd*/device/wwid");

    foreach my $file (@glob) {
        open(my $fh, "<", $file) or die "unable to open wwid file\n";
        my $line = <$fh>;
        close $fh;

        next if $line !~ m/$volume_status->{wwid}/i;

        $file = substr($file,0,-4) . "rescan";
        my ($out_file) = $file =~ /(^\/sys\/class\/block\/dm-\d+\/slaves\/sd\w+\/device\/rescan$)/;
        if ( !$out_file ) {
            die "unable to check SCSI rescan file\n";
        }
        open(my $output, ">", $out_file) or die "unable to open SCSI rescan file\n";
        print $output  "1\n" or die "unable to write to SCSI rescan file\n";
        close $output;
    }
}

sub resize_map {
    my ($class, $scfg, $volname) = @_;

    my $volume_status = $class->volume_status($scfg, $class->volume_name($scfg->{vname_prefix},$volname))
        or die "volume is not activated; unable to resize map\n";

    run_command(['multipathd', 'resize', 'map', lc "3$volume_status->{wwid}"],
        errmsg => "unable to resize multipath map\n");
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

    my $cmd = ['/usr/bin/ssh','-i', $id_rsa_path . $scfg->{address}.'_id_rsa', $scfg->{user} . '@' . $scfg->{address}, 'showvv', '-showcols', 'Name,VV_WWN', $class->volume_name($scfg->{vname_prefix},$volname, $snapname)];
    my $correct_wwn = undef;

    run_command($cmd, errmsg => "unable to read wwn information from 3par\n", outfunc => sub {
        my $line = shift;
        my ($vv_name, $wwn) = split ' ', $line;

        return if !$vv_name || !$wwn;
        return if $vv_name ne $class->volume_name($scfg->{vname_prefix},$volname, $snapname);

        $correct_wwn = lc $wwn if $vv_name eq $class->volume_name($scfg->{vname_prefix},$volname, $snapname);
    });

    die "unable to get wwn device path\n" if !defined($correct_wwn);

    ( $correct_wwn ) = ($correct_wwn =~ m/^([a-f0-9]+)$/) or die "bad WWN " . $correct_wwn; # untaint
    my $path = "/dev/mapper/3" . $correct_wwn;

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

    print "Activate volume " . $volname . "\n";

    my $volume_status = $class->volume_status($scfg, $class->volume_name($scfg->{vname_prefix},$volname, $snapname));
    if ( $volume_status ) {
        print "Lun has already been created and activated\n";
    } else
    {
        my $cmd = ['/usr/bin/ssh','-i', $id_rsa_path . $scfg->{address}.'_id_rsa', $scfg->{user} . '@' . $scfg->{address}, 'createvlun', '-novcn', '-f',
        $class->volume_name($scfg->{vname_prefix},$volname, $snapname), $scfg->{startvlun} . "+", hostname()];
        $volume_status = $class->volume_status($scfg, $class->volume_name($scfg->{vname_prefix},$volname, $snapname));

        run_command($cmd, errmsg => "failure creating vlun\n")
            if !$volume_status;

        $volume_status = $class->volume_status($scfg, $class->volume_name($scfg->{vname_prefix},$volname, $snapname));

    }
    my $dev_filename = "/dev/mapper/3" . lc $volume_status->{wwid};
    my @glob = glob("/sys/class/scsi_host/host*/scan");

    print "Scanning multipath wwn " . lc $volume_status->{wwid} . "...\n";

    foreach my $file (@glob) {
        $file = $1 if $file =~ m/^(.+)$/;
        open(my $fh, ">", $file) or die "unable to open SCSI scan file\n";
        print $fh "- - " . $volume_status->{lun};
        close $fh;
    }

    my $time = 10;
    while ( $time > 0 ) {
       last if -e $dev_filename;
       print "Wait " . $time . " seconds...\n";
       sleep 1;
       $time -= 1;
    }

   die "failure scanning for multipath devices" unless -e $dev_filename;
   print "Scan completed successfully\n";
}

sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    my $volume_status = $class->volume_status($scfg, $class->volume_name($scfg->{vname_prefix},$volname, $snapname));

    if ( !$volume_status ) {
        return -1;
    }

    my @glob = glob("/sys/class/scsi_disk/*/device/wwid");
    my $files = [];

    foreach my $file (@glob) {
        $file = $1 if $file =~ m/^(.+)$/;
        open(my $fh, "<", $file) or die "unable to open wwid file $file\n";
        my $line = <$fh>;
        if ( defined $line ) {
            push @$files, $file if (index(lc $line, lc $volume_status->{wwid}) != -1);
        }
        close $fh;
    }

    foreach my $file (@$files) {
        my $delete = "$1/delete" if $file =~ m/(\/sys\/class\/scsi_disk\/.+\/device)\/wwid/;
        die "no file found or malformed file\n" if !$delete;
        open(my $fh, ">", $delete);
        print $fh "1" or die "unable to write to scsi delete file in sysfs $delete\n";
        close $fh;
    }

    print "Unexporting volume " . $volname . " on 3par\n";

    my $cmd = ['/usr/bin/ssh','-i', $id_rsa_path . $scfg->{address}.'_id_rsa', $scfg->{user} . '@' . $scfg->{address}, 'removevlun', '-f',
        $class->volume_name($scfg->{vname_prefix},$volname, $snapname), $volume_status->{lun}, hostname()];

    run_command($cmd, errmsg => "unable to remove virtual lun\n");
}

sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;

    die "unsupported format '$fmt'" if $fmt ne 'raw';
    die "illegal name '$name' - sould be 'vm-$vmid-*'\n"  if $name && $name !~ m/^vm-$vmid-/;

    $size = ceil($size/1024/1024);

    my $volname = $name;
    $volname = $class->find_free_diskname($storeid, $scfg, $vmid, $fmt) if !$volname;


    my $cmd = ['/usr/bin/ssh','-i', $id_rsa_path . $scfg->{address}.'_id_rsa', $scfg->{user} . '@' . $scfg->{address}, 'createvv'];

    push @$cmd, '-compr' if $scfg->{use_compr};
    push @$cmd, '-tdvv' if $scfg->{use_dedup};
    push @$cmd, '-tpvv' if $scfg->{use_thin} && !$scfg->{use_dedup};
    push @$cmd, '-snp_cpg', $scfg->{cpg}, $scfg->{cpg}, $class->volume_name($scfg->{vname_prefix},$volname), $size . "G";

    run_command($cmd, errmsg => "failure creating virtual volume\n");

    return $volname;
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase) = @_;

    $class->deactivate_volume($storeid, $scfg, $volname)
        if $class->volume_status($scfg,  $class->volume_name($scfg->{vname_prefix},$volname) );

    my $cmd = ['/usr/bin/ssh','-i', $id_rsa_path . $scfg->{address}.'_id_rsa', $scfg->{user} . '@' . $scfg->{address}, 'removevv', '-f', $class->volume_name($scfg->{vname_prefix},$volname)];

    run_command($cmd, errmsg => "unable to remove virtual volume\n");
}


sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;
    
    my $cmd = ['/usr/bin/ssh','-i', $id_rsa_path . $scfg->{address}.'_id_rsa', $scfg->{user} . '@' . $scfg->{address}, 'showvv', '-notree' ,'-p', '-cpg', $scfg->{cpg}, '-showcols', 'Name,VSize_MB'];
    my $res = [];

    run_command($cmd, outfunc => sub {
        my $line = shift;
        my ($name, $size) = split ' ', $line;


        return if !$name || !$size;

        return if $name !~ m/^$scfg->{vname_prefix}vm-(\d+)-/;
        my $owner = $1;
        return if $size !~ m/^\d+$/;

	$name =~ s/^$scfg->{vname_prefix}//;
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

    my $cmd = ['/usr/bin/ssh','-i', $id_rsa_path . $scfg->{address}.'_id_rsa', $scfg->{user} . '@' . $scfg->{address}, 'showsys', '-space'];
    my $free = 0;
    my $total = 0;
    print $cmd;

    run_command($cmd, outfunc => sub {
        my $line = shift;
        $total = $1 * 1024 * 1024 if $line =~ m/^Total Capacity\s+:\s+(\d+)/;
        $free = $1 * 1024 * 1024 if $line =~ m/^\s+Free\s+:\s+(\d+)/;
    }, errmsg => "unable to showsys\n");

    return ($total, $free, $total - $free, 1);
}

sub volume_resize {
    my ($class, $scfg, $storeid, $volname, $size, $running) = @_;
    my $disks = $class->list_images($storeid, $scfg);
    my $volid = "$storeid:$volname";

    foreach my $cur ( @$disks )
    {
	if ($cur->{volid} eq $volid)
	{
	    die "cannot shrink volume\n" if $size < $cur->{size};
	    my $cmd = ['/usr/bin/ssh','-i', $id_rsa_path . $scfg->{address}.'_id_rsa', $scfg->{user} . '@' . $scfg->{address}, 'growvv', '-f',
	    $class->volume_name($scfg->{vname_prefix},$volname), ($size - $cur->{size})/1073741824 . 'G'];
	    run_command($cmd, errmsg => "error resizing volume\n");
	    $class->rescan_vol($scfg, $volname);
	    $class->resize_map($scfg, $volname);
	    return;
	}
    }
    die "error resizing volume, volume $volname not found \n";
}

sub volume_snapshot {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;
    my $vv = $scfg->{vname_prefix} . $volname;
    my $cmd = ['/usr/bin/ssh','-i', $id_rsa_path . $scfg->{address}.'_id_rsa', $scfg->{user} . '@' . $scfg->{address}, 'createsv', '-ro'];

    push @$cmd, '-exp', $scfg->{snapshot_expiry} if $scfg->{snapshot_expiry};
    push @$cmd, "${vv}_${snap}", $vv;

    run_command($cmd, errmsg => "unable to create snapshot of virtual volume\n");
}

sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    $class->deactivate_volume($storeid, $scfg, $volname, $snap)
        if $class->volume_status($scfg,  $class->volume_name($scfg->{vname_prefix},$volname) );

    my $cmd = ['/usr/bin/ssh','-i', $id_rsa_path . $scfg->{address}.'_id_rsa', $scfg->{user} . '@' . $scfg->{address}, 'promotesv',
        $class->volume_name($scfg->{vname_prefix},$volname, $snap)];

    run_command($cmd, errmsg => "unable to rollback snapshot\n", outfunc => sub {
        my $line = shift;
        my (undef, $taskid) = split ' ', $line;

	if ($taskid)
	{
		$cmd = ['/usr/bin/ssh','-i', $id_rsa_path . $scfg->{address}.'_id_rsa', $scfg->{user} . '@' . $scfg->{address}, 'waittask', $taskid] if $taskid;
	        run_command($cmd, errmsg => "unable to wait for rollback to snapshot\n");
	}
    });
}

sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    die "no snapname given (cowardly refusing to delete base volume from snapshot delete command)\n"
        if !$snap;

    $class->free_image($storeid, $scfg, $volname.'_'.$snap, undef);
}

sub volume_export_formats {
    my ($class, $scfg, $storeid, $volname, $snapshot, $base_snapshot, $with_snapshots) = @_;

    die "Not implemented\n";
}

sub volume_export {
    my ($class, $scfg, $storeid, $fh, $volname, $format, $snapshot, $base_snapshot, $with_snapshots) = @_;

    die "Not implemented\n";
}

sub volume_import {
    my ($class, $scfg, $storeid, $fh, $volname, $format, $base_snapshot, $with_snapshots) = @_;

    die "Not implemented\n";
}

sub volume_has_feature {
    my ($class, $scfg, $feature, $storeid, $volname, $snapname, $running) = @_;

    my $features = {
        snapshot => { current => 1, snap => 1},
        clone => { base => 1},
        template => { current => 1},
        copy => { base => 1, current => 1},
    };

    my ($vtype, $name, $vmid, $basename, $basevmid, $isBase) =
        $class->parse_volname($volname);

    my $key = undef;

    if ($snapname) {
        $key = 'snap';
    } else {
        $key = $isBase ? 'base' : 'current';
    }

    return 1 if $features->{$feature}->{$key};

    return undef;
}

1;
