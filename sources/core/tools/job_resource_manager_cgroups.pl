# $Id$
# 
# The job_resource_manager_cgroups script is a perl script that oar server
# deploys on nodes to manage cpusets, users, job keys, ...
#
# In this script some cgroup Linux features are added in addition to cpuset:
#     - Tag each network packet from processes of this job with the class id =
#       $OAR_JOB_ID
#     - Put an IO share corresponding to the ratio between reserved cpus and
#       the number of the node
#
# Usage:
# This script is deployed from the server and executed as oar on the nodes
# ARGV[0] can have two different values:
#     - "init"  : then this script must create the right cpuset and assign
#                 corresponding cpus
#     - "clean" : then this script must kill all processes in the cpuset and
#                 clean the cpuset structure

# TAKTUK_HOSTNAME environment variable must be defined and must be a name
# that we will be able to find in the transfered hashtable ($Cpuset variable).
use Fcntl ':flock';
#use Data::Dumper;

sub exit_myself($$);
sub print_log($$);

my $Old_umask = sprintf("%lo",umask());
umask(oct("022"));

my $Cgroup_mount_point = "/dev/oar_cgroups";
my $Cpuset;
my $Log_level;

# Retrieve parameters from STDIN in the "Cpuset" structure which looks like: 
# $Cpuset = {
#               job_id => id of the corresponding job
#               name => "cpuset name",
#               cpuset_path => "relative path in the cpuset FS",
#               nodes => hostname => [array with the content of the database cpuset field]
#               ssh_keys => {
#                               public => {
#                                           file_name => "~oar/.ssh/authorized_keys"
#                                           key => "public key content"
#                                         }
#                               private => {
#                                           file_name => "directory where to store the private key"
#                                           key => "private key content"
#                                          }
#                           }
#               oar_tmp_directory => "path to the temp directory"
#               user => "user name"
#               job_user => "job user"
#               job_uid => "job uid for the job_user if needed"
#               types => hashtable with job types as keys
#               log_level => debug level number
#           }
my $tmp = "";
while (<STDIN>){
    $tmp .= $_;
}
$Cpuset = eval($tmp);

if (!defined($Cpuset->{log_level})){
    exit_myself(2,"Bad SSH hashtable transfered");
}
$Log_level = $Cpuset->{log_level};
my $Cpuset_path_job;
my @Cpuset_cpus;
# Get the data structure only for this node
if (defined($Cpuset->{cpuset_path})){
    $Cpuset_path_job = $Cpuset->{cpuset_path}.'/'.$Cpuset->{name};
    @Cpuset_cpus = @{$Cpuset->{nodes}->{$ENV{TAKTUK_HOSTNAME}}};
}



print_log(3,"$ARGV[0]");
if ($ARGV[0] eq "init"){
    # Initialize cpuset for this node
    # First, create the tmp oar directory
    if (!(((-d $Cpuset->{oar_tmp_directory}) and (-O $Cpuset->{oar_tmp_directory})) or (mkdir($Cpuset->{oar_tmp_directory})))){
        exit_myself(13,"Directory $Cpuset->{oar_tmp_directory} does not exist and cannot be created");
    }

    if (defined($Cpuset->{job_uid})){
        my $prevuser = getpwuid($Cpuset->{job_uid});
        system("oardodo /usr/sbin/userdel -f $prevuser") if (defined($prevuser));
        my @tmp = getpwnam($Cpuset->{user});
        if ($#tmp < 0){
            exit_myself(15,"Cannot get information from user '$Cpuset->{user}'");
        }
        if (system("oardodo /usr/sbin/adduser --disabled-password --gecos 'OAR temporary user' --no-create-home --force-badname --quiet --home $tmp[7] --gid $tmp[3] --shell $tmp[8] --uid $Cpuset->{job_uid} $Cpuset->{job_user}")){
            exit_myself(15,"Failed to create $Cpuset->{job_user} with uid $Cpuset->{job_uid} and home $tmp[7] and group $tmp[3] and shell $tmp[8]");
        }
    }

    if (defined($Cpuset_path_job)){
        if (open(LOCKFILE,"> $Cpuset->{oar_tmp_directory}/job_manager_lock_file")){
            flock(LOCKFILE,LOCK_EX) or exit_myself(17,"flock failed: $!");
            if (!(-r $Cgroup_mount_point.'/tasks')){
                if (system('oardodo mkdir -p '.$Cgroup_mount_point.' && oardodo mount -t cgroup -o cpuset,cpu,cpuacct,devices,freezer,net_cls,blkio none '.$Cgroup_mount_point.'; oardodo rm -f /dev/cpuset; oardodo ln -s '.$Cgroup_mount_point.' /dev/cpuset')){
                    exit_myself(4,"Failed to mount cgroup pseudo filesystem");
                }
            }
            if (!(-d $Cgroup_mount_point.'/'.$Cpuset->{cpuset_path})){
                if (system( 'oardodo mkdir -p '.$Cgroup_mount_point.'/'.$Cpuset->{cpuset_path}.' &&'. 
                            'oardodo chown -R oar '.$Cgroup_mount_point.'/'.$Cpuset->{cpuset_path}.' &&'.
                            '/bin/echo 0 | cat > '.$Cgroup_mount_point.'/'.$Cpuset->{cpuset_path}.'/notify_on_release && '.
                            '/bin/echo 0 | cat > '.$Cgroup_mount_point.'/'.$Cpuset->{cpuset_path}.'/cpuset.cpu_exclusive && '.
                            'cat '.$Cgroup_mount_point.'/cpuset.mems > '.$Cgroup_mount_point.'/'.$Cpuset->{cpuset_path}.'/cpuset.mems &&'.
                            'cat '.$Cgroup_mount_point.'/cpuset.cpus > '.$Cgroup_mount_point.'/'.$Cpuset->{cpuset_path}.'/cpuset.cpus &&'.
                            '/bin/echo 1000 | cat > '.$Cgroup_mount_point.'/'.$Cpuset->{cpuset_path}.'/blkio.weight'

                        )){
                    exit_myself(4,"Failed to create cgroup $Cpuset->{cpuset_path}");
                }
            }
            flock(LOCKFILE,LOCK_UN) or exit_myself(17,"flock failed: $!");
            close(LOCKFILE);
        }else{
            exit_myself(16,"Failed to open or create $Cpuset->{oar_tmp_directory}/job_manager_lock_file");
        }
#'for c in '."@Cpuset_cpus".';do cat /sys/devices/system/cpu/cpu$c/topology/physical_package_id > /dev/cpuset/'.$Cpuset_path_job.'/mems; done && '.

# Be careful with the physical_package_id. Is it corresponding to the memory banc?
        if (system( 'oardodo mkdir -p '.$Cgroup_mount_point.'/'.$Cpuset_path_job.' && '.
                    'oardodo chown -R oar '.$Cgroup_mount_point.'/'.$Cpuset_path_job.' && '.
                    '/bin/echo 0 | cat > '.$Cgroup_mount_point.'/'.$Cpuset_path_job.'/notify_on_release && '.
                    '/bin/echo 0 | cat > '.$Cgroup_mount_point.'/'.$Cpuset_path_job.'/cpuset.cpu_exclusive && '.
                    'cat '.$Cgroup_mount_point.'/cpuset.mems > '.$Cgroup_mount_point.'/'.$Cpuset_path_job.'/cpuset.mems && '.
                    '/bin/echo '.join(",",@Cpuset_cpus).' | cat > '.$Cgroup_mount_point.'/'.$Cpuset_path_job.'/cpuset.cpus'
                  )){
            exit_myself(5,"Failed to create and feed the cpuset $Cpuset_path_job");
        }

        # Tag network packets from processes of this job
        if (system( '/bin/echo '.$Cpuset->{job_id}.' | cat > '.$Cgroup_mount_point.'/'.$Cpuset_path_job.'/net_cls.classid'
            )){
            exit_myself(5,"Failed to tag network packets of the cgroup $Cpuset_path_job");
        }
        # Put a share for IO disk corresponding of the ratio between the number
        # of cpus of this cgroup and the number of cpus of the node
        my @cpu_cgroup_uniq_list;
        my %cpu_cgroup_name_hash;
        foreach my $i (@Cpuset_cpus){
            if (!defined($cpu_cgroup_name_hash{$i})){
                $cpu_cgroup_name_hash{$i} = 1;
                push(@cpu_cgroup_uniq_list, $i);
            }
        }
        # Get the whole cpus of the node
        my @node_cpus;
        if (open(CPUS, "$Cgroup_mount_point/cpuset.cpus")){
            my $str = <CPUS>;
            chop($str);
            $str =~ s/\-/\.\./g;
            @node_cpus = eval($str);
            close(CPUS);
        }else{
            exit_myself(5,"Failed to retrieve the cpu list of the node $Cgroup_mount_point/cpuset.cpus");
        }
        my $IO_ratio = sprintf("%.0f",(($#cpu_cgroup_uniq_list + 1) / ($#node_cpus + 1) * 1000)) ;
        if (system( '/bin/echo '.$IO_ratio.' | cat > '.$Cgroup_mount_point.'/'.$Cpuset_path_job.'/blkio.weight')){
            exit_myself(5,"Failed to set the blkio.weight to $IO_ratio");
        }
    }

    # Copy ssh key files
    if ($Cpuset->{ssh_keys}->{private}->{key} ne ""){
        # private key
        if (open(PRIV, ">".$Cpuset->{ssh_keys}->{private}->{file_name})){
            chmod(0600,$Cpuset->{ssh_keys}->{private}->{file_name});
            if (!print(PRIV $Cpuset->{ssh_keys}->{private}->{key})){
                unlink($Cpuset->{ssh_keys}->{private}->{file_name});
                exit_myself(8,"Error writing $Cpuset->{ssh_keys}->{private}->{file_name}");
            }
            close(PRIV);
            if (defined($Cpuset->{job_uid})){
                system("ln -s $Cpuset->{ssh_keys}->{private}->{file_name} $Cpuset->{oar_tmp_directory}/$Cpuset->{job_user}.jobkey");
            }
        }else{
            exit_myself(7,"Error opening $Cpuset->{ssh_keys}->{private}->{file_name}");
        }

        # public key
        if (open(PUB,"+<",$Cpuset->{ssh_keys}->{public}->{file_name})){
            flock(PUB,LOCK_EX) or exit_myself(17,"flock failed: $!");
            seek(PUB,0,0) or exit_myself(18,"seek failed: $!");
            my $out = "\n".$Cpuset->{ssh_keys}->{public}->{key}."\n";
            while (<PUB>){
                if ($_ =~ /environment=\"OAR_KEY=1\"/){
                    # We are reading a OAR key
                    $_ =~ /(ssh-dss|ssh-rsa)\s+([^\s^\n]+)/;
                    my $oar_key = $2;
                    $Cpuset->{ssh_keys}->{public}->{key} =~ /(ssh-dss|ssh-rsa)\s+([^\s^\n]+)/;
                    my $curr_key = $2;
                    if ($curr_key eq $oar_key){
                        exit_myself(13,"ERROR: the user has specified the same ssh key than used by the user oar");
                    }
                    $out .= $_;
                }elsif ($_ =~ /environment=\"OAR_CPUSET=([\w\/]+)\"/){
                    # Remove from authorized keys outdated keys (typically after a reboot)
                    if (-d "/dev/cpuset/$1"){
                        $out .= $_;
                    }
                }else{
                    $out .= $_;
                }
            }
            if (!(seek(PUB,0,0) and print(PUB $out) and truncate(PUB,tell(PUB)))){
                exit_myself(9,"Error writing $Cpuset->{ssh_keys}->{public}->{file_name}");
            }
            flock(PUB,LOCK_UN) or exit_myself(17,"flock failed: $!");
            close(PUB);
        }else{
            unlink($Cpuset->{ssh_keys}->{private}->{file_name});
            exit_myself(10,"Error opening $Cpuset->{ssh_keys}->{public}->{file_name}");
        }
    }
}elsif ($ARGV[0] eq "clean"){
    # delete ssh key files
    if ($Cpuset->{ssh_keys}->{private}->{key} ne ""){
        # private key
        unlink($Cpuset->{ssh_keys}->{private}->{file_name});
        if (defined($Cpuset->{job_uid})){
            unlink("$Cpuset->{oar_tmp_directory}/$Cpuset->{job_user}.jobkey");
        }

        # public key
        if (open(PUB,"+<", $Cpuset->{ssh_keys}->{public}->{file_name})){
            flock(PUB,LOCK_EX) or exit_myself(17,"flock failed: $!");
            seek(PUB,0,0) or exit_myself(18,"seek failed: $!");
            #Change file on the fly
            my $out = "";
            while (<PUB>){
                if (($_ ne "\n") and ($_ ne $Cpuset->{ssh_keys}->{public}->{key})){
                    $out .= $_;
                }
            }
            if (!(seek(PUB,0,0) and print(PUB $out) and truncate(PUB,tell(PUB)))){
                exit_myself(12,"Error changing $Cpuset->{ssh_keys}->{public}->{file_name}");
            }
            flock(PUB,LOCK_UN) or exit_myself(17,"flock failed: $!");
            close(PUB);
        }else{
            exit_myself(11,"Error opening $Cpuset->{ssh_keys}->{public}->{file_name}");
        }
    }

    # Clean cpuset on this node
    if (defined($Cpuset_path_job)){
        system('PROCESSES=$(cat '.$Cgroup_mount_point.'/'.$Cpuset_path_job.'/tasks)
                while [ "$PROCESSES" != "" ]
                do
                    oardodo kill -9 $PROCESSES
                    PROCESSES=$(cat '.$Cgroup_mount_point.'/'.$Cpuset_path_job.'/tasks)
                done'
              );

        if (system('oardodo rmdir '.$Cgroup_mount_point.'/'.$Cpuset_path_job)){
            # Uncomment this line if you want to use several network_address properties
            # which are the same physical computer (linux kernel)
            #exit(0);
            exit_myself(6,"Failed to delete the cgroup $Cpuset_path_job");
        }
    }
    print("DEBUG $Cpuset->{job_uid} $Cpuset->{job_user} \n");
    if (defined($Cpuset->{job_uid})){
        my $ipcrm_args="";
        if (open(IPCMSG,"< /proc/sysvipc/msg")) {
            <IPCMSG>;
            while (<IPCMSG>) {
                if (/^\s*\d+\s+(\d+)(?:\s+\d+){5}\s+$Cpuset->{job_uid}(?:\s+\d+){6}$/) {
                    $ipcrm_args .= " -q $1";
                } else {
                    print_log(3,"Cannot parse IPC MSG: $_.");
                }
            }
            close (IPCMSG);
        }else{
            exit_myself(14,"Cannot open /proc/sysvipc/msg: $!");
        }
        if (open(IPCSHM,"< /proc/sysvipc/shm")) {
            <IPCSHM>;
            while (<IPCSHM>) {
                if (/^\s*\d+\s+(\d+)(?:\s+\d+){5}\s+$Cpuset->{job_uid}(?:\s+\d+){6}$/) {
                    $ipcrm_args .= " -m $1";
                } else {
                    print_log(3,"Cannot parse IPC SHM: $_.");
                }
            }
            close (IPCSHM);
        }else{
            exit_myself(14,"Cannot open /proc/sysvipc/shm: $!");
        }
        if (open(IPCSEM,"< /proc/sysvipc/sem")) {
            <IPCSEM>;
            while (<IPCSEM>) {
                if (/^\s*\d+\s+(\d+)(?:\s+\d+){2}\s+$Cpuset->{job_uid}(?:\s+\d+){5}$/) {
                    $ipcrm_args .= " -s $1";
                } else {
                    print_log(3,"Cannot parse IPC SEM: $_.\n");
                }
            }
            close (IPCSEM);
        }else{
            exit_myself(14,"Cannot open /proc/sysvipc/sem: $!");
        }
        if ($ipcrm_args) {
            print_log(3,"Purging SysV IPC: ipcrm $ipcrm_args");
            if(system("oardodo ipcrm $ipcrm_args")){
                exit_myself(14,"Failed to purge IPC: ipcrm $ipcrm_args");
            }
        }
        print_log(3,"Purging /tmp...");
        #system("oardodo find /tmp/ -user $Cpuset->{job_user} -exec rm -rfv {} \\;");
        system("oardodo find /tmp/. -user $Cpuset->{job_user} -delete"); 
        system("oardodo /usr/sbin/userdel -f $Cpuset->{job_user}");
    }
}else{
    exit_myself(3,"Bad command line argument $ARGV[0]");
}

exit(0);

# Print error message and exit
sub exit_myself($$){
    my $exit_code = shift;
    my $str = shift;

    warn("[job_resource_manager_cgroups][$Cpuset->{job_id}][ERROR] ".$str."\n");
    exit($exit_code);
}

# Print log message depending on the LOG_LEVEL config value
sub print_log($$){
    my $l = shift;
    my $str = shift;

    if ($l <= $Log_level){
        print("[job_resource_manager_cgroups][$Cpuset->{job_id}][DEBUG] $str\n");
    }
}
