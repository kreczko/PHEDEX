package PHEDEX::Transfer::FTS; use base 'PHEDEX::Transfer::Core';

use strict;
use warnings;

use Getopt::Long;
use POSIX;
use Data::Dumper;


use PHEDEX::Transfer::Backend::Job;
use PHEDEX::Transfer::Backend::File;
use PHEDEX::Transfer::Backend::Monitor;
use PHEDEX::Transfer::Backend::Interface::Glite;
use PHEDEX::Core::Command;
use PHEDEX::Core::Timing;
use PHEDEX::Monalisa;
use POE;

sub new
{
    my $proto = shift;
    my $class = ref($proto) || $proto;
    my $master = shift;
    
    # Get derived class arguments and defaults
    my $options = shift || {};
    my $params = shift || {};

    # Set my defaults where not defined by the derived class.
    $params->{PROTOCOLS}           ||= [ 'srm' ];  # Accepted protocols
    $params->{BATCH_FILES}         ||= 30;         # Max number of files per job
    $params->{FTS_LINK_PEND}       ||= 5;          # Submit to FTS until this number of files per link are "pending"
    $params->{FTS_MAX_ACTIVE}      ||= 300;        # Submit to FTS until these number of files are "active"
    $params->{FTS_DEFAULT_LINK_ACTIVE} ||= undef;  # Optional default per-link limits to number of active files
    $params->{FTS_LINK_ACTIVE}     ||= {};         # Optional per-link limits to number of active files
    $params->{FTS_POLL_QUEUE}      ||= 0;          # Whether to poll all vs. our jobs
    $params->{FTS_Q_INTERVAL}      ||= 30;         # Interval for polling queue for new jobs
    $params->{FTS_J_INTERVAL}      ||= 5;          # Interval for polling individual jobs

    # Set argument parsing at this level.
    $options->{'batch-files=i'}        = \$params->{BATCH_FILES};
    $options->{'link-pending-files=i'} = \$params->{FTS_LINK_PEND};
    $options->{'max-active-files=i'}   = \$params->{FTS_MAX_ACTIVE};
    $options->{'default-link-active-files=i'} = \$params->{FTS_DEFAULT_LINK_ACTIVE};
    $options->{'link-active-files=i'}  =  $params->{FTS_LINK_ACTIVE};
    $options->{'service=s'}            = \$params->{FTS_SERVICE};
    $options->{'myproxy=s'}            = \$params->{FTS_MYPROXY};
    $options->{'passfile=s'}           = \$params->{FTS_PASSFILE};
    $options->{'spacetoken=s'}         = \$params->{FTS_SPACETOKEN};
    $options->{'priority=s'}           = \$params->{FTS_PRIORITY};
    $options->{'mapfile=s'}            = \$params->{FTS_MAPFILE};
    $options->{'q_interval=i'}         = \$params->{FTS_Q_INTERVAL};
    $options->{'j_interval=i'}         = \$params->{FTS_J_INTERVAL};
    $options->{'poll_queue=i'}         = \$params->{FTS_POLL_QUEUE};
    $options->{'monalisa_host=s'}      = \$params->{FTS_MONALISA_HOST};
    $options->{'monalisa_port=i'}      = \$params->{FTS_MONALISA_PORT};
    $options->{'monalisa_cluster=s'}   = \$params->{FTS_MONALISA_CLUSTER};
    $options->{'monalisa_node=s'}      = \$params->{FTS_MONALISA_NODE};

    # Initialise myself
    my $self = $class->SUPER::new($master, $options, $params, @_);
    bless $self, $class;

    $self->init();
    $self->Dbgmsg('FTS $self:  ', Dumper($self)) if $self->{DEBUG};
    return $self;
}

sub init
{
    my ($self) = @_;

    my $glite = PHEDEX::Transfer::Backend::Interface::Glite->new
	(
	 SERVICE => $self->{FTS_SERVICE},
	 ME      => 'GLite',
	 );

    $glite->MYPROXY($self->{FTS_MYPROXY}) if $self->{FTS_MYPROXY};
    $glite->SPACETOKEN($self->{FTS_SPACETOKEN}) if $self->{FTS_SPACETOKEN};

    if ($self->{FTS_PASSFILE}) {
	my $passfile = $self->{FTS_PASSFILE};
	my $ok = 1;
	if (! -f $passfile) {
	    $self->Alert("FTS passfile '$passfile' does not exist");
	    $ok = 0;
	} elsif (! -r $passfile) {
	    $self->Alert("FTS passfile '$passfile' is not readable");
	    $ok = 0;
	} elsif ( (stat($passfile))[2] != 0100600) {
	    $self->Warn("FTS passfile '$passfile' has vulnerable file access permissions, ",
			"please restrict with 'chmod 600 $passfile'");
	}

	if ($ok) {
	    open PASSFILE, "< $passfile" or die $!;
	    my $pass = <PASSFILE>; chomp $pass;
	    close PASSFILE;
	    $glite->PASSWORD($pass);
	}
    }

    $self->{Q_INTERFACE} = $glite;

    my $monalisa;
    my $use_monalisa = 1;
    foreach (qw(FTS_MONALISA_HOST FTS_MONALISA_PORT FTS_MONALISA_CLUSTER FTS_MONALISA_NODE)) {
	$use_monalisa &&= exists $self->{$_} && defined $self->{$_};
    }

    if ( $use_monalisa )
    {
	$monalisa = PHEDEX::Monalisa->new
	    (
	     Host    => $self->{FTS_MONALISA_HOST}.':'.$self->{FTS_MONALISA_PORT},
	     Cluster => $self->{FTS_MONALISA_CLUSTER},
	     Node    => $self->{FTS_MONALISA_NODE},
	     apmon   => { sys_monitoring => 0,
			  general_info   => 0 }
	     );

	$self->{MONALISA} = $monalisa;
    }

    my $q_mon = PHEDEX::Transfer::Backend::Monitor->new
	(
	 Q_INTERFACE   => $glite,
	 Q_INTERVAL    => $self->{FTS_Q_INTERVAL},
	 J_INTERVAL    => $self->{FTS_J_INTERVAL},
	 POLL_QUEUE    => $self->{FTS_POLL_QUEUE},
	 APMON         => $monalisa,
	 ME            => 'QMon',
	 );

    $self->{FTS_Q_MONITOR} = $q_mon;

    $self->parseFTSmap() if ($self->{FTS_MAPFILE});

    # A limit to the number of jobs is the "live" file, which
    # must be touched for every job within 5 minutes or FileDownload
    # will throw the job away.  Because we poll jobs at a fixed rate,
    # we must limit the number of jobs to keep this file from getting
    # to old.  By default this limits us to 60 jobs.  TODO: Find a way
    # around this limit
    $self->{NJOBS} = 5*60 / $self->{FTS_J_INTERVAL};

    # How do we handle task-priorities?
    # If priorities have been specified on the command-line, they should
    # have the syntax 'm1=p1,m2=p2,m3=p3', where p<n> is the task priority
    # from TMDB and m<n> is the priority to map it to. For all p<n> that do
    # not get overridden on the command-line, the priority is taken as given.
    #
    # PhEDEx task priorities are 0-5, high to low. FTS is 1-5, low to high.
    # Map PhEDEx to the mid-range so we have some margin to play with.
    $self->{PRIORITY_MAP} =
	{
	  0 => 4,
	  1 => 4,
	  2 => 3,
	  3 => 3,
	  4 => 2,
	  5 => 2,
	};
    if ( $self->{FTS_PRIORITY} )
    {
      foreach ( split(',',$self->{FTS_PRIORITY}) )
      {
        $self->Fatal("Corrupt Priority specification \"$_\"")
		unless m%^(.*)=(.*)$%;
        $self->{PRIORITY_MAP}{$1} = $2;
      }
    }
}

# FTS map parsing
# The ftsmap file has the following format:
# SRM.Endpoint="srm://cmssrm.fnal.gov:8443/srm/managerv2" FTS.Endpoint="https://cmsstor20.fnal.gov:8443/glite-data-transfer-fts/services/FileTransfer"
# SRM.Endpoint="DEFAULT" FTS.Endpoint="https://cmsstor20.fnal.gov:8443/glite-data-transfer-fts/services/FileTransfer"

sub parseFTSmap {
    my $self = shift;

    my $mapfile = $self->{FTS_MAPFILE};

    # hash srmendpoint=>ftsendpoint;
    my $map = {};

    if (!open MAP, "$mapfile") {	
	$self->Alert("FTSmap: Could not open ftsmap file $mapfile");
	return 1;
    }

    while (<MAP>) {
	chomp; 
	s|^\s+||; 
	next if /^\#/;
	unless ( /^SRM.Endpoint=\"(.+)\"\s+FTS.Endpoint=\"(.+)\"/ ) {
	    $self->Alert("FTSmap: Can not parse ftsmap line: '$_'");
	    next;
	}

	$map->{$1} = $2;
    }

    unless (defined $map->{DEFAULT}) {
	$self->Alert("FTSmap: Default FTS endpoit is not defined in the ftsmap file $mapfile");
	return 1;
    }

    $self->{FTS_MAP} = $map;
    
    return 0;
}

sub getFTSService {
    my $self = shift;
    my $to_pfn = shift;

    my $service;

    my ($endpoint) = ( $to_pfn =~ /(srm.+)\?SFN=/ );

    unless ($endpoint) {
	$self->Alert("FTSmap: Could not get the end point from to_pfn $to_pfn");
    }

    if ( exists $self->{FTS_MAP} ) {
	my $map = $self->{FTS_MAP};

	$service = $map->{ (grep { $_ eq $endpoint } keys %$map)[0] || "DEFAULT" };
	$self->Alert("FTSmap: Could not get FTS service endpoint from ftsmap file for $endpoint") unless $service;
    }

    # fall back to command line option
    $service ||= $self->{FTS_SERVICE};

    return $service;
}

# If $to and $from are not given, then the question is:
# "Are you too busy to take ANY transfers?"
# If they are provided, then the question is:
# "Are you too busy to take transfers on link $from -> $to?"
sub isBusy
{
    my ($self, $jobs, $tasks, $to, $from)  = @_;
    my ($stats, $busy);
    $busy = 0;

    # FTS states to consider as "pending"
    my @pending_states = ('Ready', 'Pending', 'undefined');

    # FTS states to consider as "active".  This includes the pending
    # states, because we expect they will become active at some point.
    my @active_states = ('Active', @pending_states);

    # Check if our global job limit is reached
    if (scalar(keys %$jobs) >= $self->{NJOBS}) {
	$self->Logmsg("FTS is busy:  maximum number of jobs ($self->{NJOBS}) reached") 
	    if $self->{VERBOSE};
	return 1;
    }
    
    if (defined $from && defined $to) {
	# Check per-link busy status based on a maximum number of
	# "pending" files per link.  Treat undefined as pending until
	# their state is resolved.
	$stats = $self->{FTS_Q_MONITOR}->{LINKSTATS};

	my %state_counts;
	foreach my $file (keys %$stats) {
	    if (exists $stats->{$file}{$from}{$to}) {
		$state_counts{ $stats->{$file}{$from}{$to} }++;
	    }
	}
	
	$self->Dbgmsg("Transfer::FTS::isBusy Link Stats $from->$to\n",
		      Dumper(\%state_counts)) if $self->{DEBUG};
	
	if ($self->{FTS_LINK_ACTIVE}->{$from} || $self->{FTS_DEFAULT_LINK_ACTIVE}) {
	    # Count files in the Active state
	    my $n_active = 0;
	    foreach ( @active_states )
	    {
		if ( defined($state_counts{$_}) ) { $n_active += $state_counts{$_}; }
	    }
	    
	    # Compare to our limit
	    my $limit;
	    $limit = $self->{FTS_DEFAULT_LINK_ACTIVE} if $self->{FTS_DEFAULT_LINK_ACTIVE};
	    $limit = $self->{FTS_LINK_ACTIVE}->{$from} if $self->{FTS_LINK_ACTIVE}->{$from};
	    
	    if ( $n_active >= $limit ) { 
		$busy = 1; 
		$self->Logmsg("FTS is busy for link $from->$to with $n_active active files\n") if $self->{VERBOSE};
	    }
	} else {
	    # Count files in the Ready, Pending or undefined state
	    my $n_pend = 0;
	    foreach ( @pending_states )
	    {
		if ( defined($state_counts{$_}) ) { $n_pend += $state_counts{$_}; }
	    }
	
	    # Compare to our limit
	    if ( $n_pend >= $self->{FTS_LINK_PEND} ) { 
		$busy = 1; 
		$self->Logmsg("FTS is busy for link $from->$to with $n_pend pending files\n") if $self->{VERBOSE};
	    }
	}
      
	$self->Dbgmsg("Transfer::FTS::isBusy for link $from->$to: busy=$busy") if $self->{DEBUG};
    } else {
	# Check total transfer busy status based on maximum number of
	# "active" files.  This is the maximum amount of parallel
	# transfer we will allow.
	$stats = $self->{FTS_Q_MONITOR}->WorkStats();
	my %state_counts;
	if ( $stats &&
	     exists $stats->{FILES} &&
	     exists $stats->{FILES}{STATES} )
	{
	    # Count the number of all file states
	    foreach ( values %{$stats->{FILES}{STATES}} ) { $state_counts{$_}++; }
	}
      
	# Count files in the Active state
	my $n_active = 0;
	foreach ( @active_states )
	{
	    if ( defined($state_counts{$_}) ) { $n_active += $state_counts{$_}; }
	}
	# If there are FTS_MAX_ACTIVE files in the Active || undefined state
	if ( $n_active >= $self->{FTS_MAX_ACTIVE} ) { 
	    $busy = 1;
	    $self->Logmsg("FTS is busy:  maximum active files ($self->{FTS_MAX_ACTIVE}) reached") if $self->{VERBOSE};
	}
	 
	$self->Dbgmsg("Transfer::FTS::isBusy in total busy=$busy") if $self->{DEBUG};
    }

    return $busy;
}


sub startBatch
{
    my ($self, $jobs, $tasks, $dir, $jobname, $list) = @_;

    my @batch = splice(@$list, 0, $self->{BATCH_FILES});
    my $info = { ID => $jobname, DIR => $dir,
                 TASKS => { map { $_->{TASKID} => 1 } @batch } };
    &output("$dir/info", Dumper($info));
    &touch("$dir/live");
    $jobs->{$jobname} = $info;

    # create the copyjob file via Job->Prepare method
    my %files = ();

    # Create a job from a group of files.
    # Because the FTS priorities are per job and the PhEDEx priorities
    # are per file (task), we take an average of the priorities of the
    # tasks in order to map that onto an FTS priority.  This should be
    # reasonable most of the time because we ought to get tasks in
    # batches of mostly the same priority.
    my $n_files = 0;
    my $sum_priority = 0;
    foreach my $taskid ( keys %{$info->{TASKS}} ) {
	my $task = $tasks->{$taskid};

	$n_files++;
	$sum_priority += $task->{PRIORITY};

	my %args = (
		    SOURCE=>$task->{FROM_PFN},
		    DESTINATION=>$task->{TO_PFN},
		    FROM_NODE=>$task->{FROM_NODE},
		    TO_NODE=>$task->{TO_NODE},
		    TASKID=>$taskid,
		    WORKDIR=>$dir,
		    START=>&mytimeofday(),
		    );
	$files{$task->{TO_PFN}} = PHEDEX::Transfer::Backend::File->new(%args);
    }
 
    my $avg_priority = int( $sum_priority / $n_files );
    $avg_priority = $self->{PRIORITY_MAP}{$avg_priority} || $avg_priority;
    my %args = (
		COPYJOB  => "$dir/copyjob",
		WORKDIR  => $dir,
		FILES    => \%files,
		VERBOSE	 => 1,
		PRIORITY => $avg_priority,
#		SERVICE => $service,
		);
    
    my $job = PHEDEX::Transfer::Backend::Job->new(%args);

    # this writes out a copyjob file
    $job->Prepare();

    # now get FTS service for the job
    # we take a first file in the job and determine
    # the FTS endpoint based on this (using ftsmap file, if given)
    my $service = $self->getFTSService( $batch[0]->{FROM_PFN} );

    unless ($service) {
	my $reason = "Cannot identify FTS service endpoint based on a sample source PFN $batch[0]->{FROM_PFN}";
	$job->Log("$reason\nSee download agent log file details, grep for\ FTSmap to see problems with FTS map file");
	foreach my $file ( values %files ) {
	    $file->Reason($reason);
	    $self->mkTransferSummary($file, $job);
	}
    }

    $job->Service($service);

    my $result = $self->{Q_INTERFACE}->Submit($job);
    $job->Log( @{$result->{INFO}} ) if $result->{INFO};

    if ( exists $result->{ERROR} ) { 
	# something went wrong...
	my $reason = "Could not submit to FTS\n";
	$job->Log( $result->{ERROR} );
	$job->RawOutput( @{$result->{RAW_OUTPUT}} );
	foreach my $file ( values %files ) {
            $file->Reason($reason);
            $self->mkTransferSummary($file, $job);
        }
	return;
    }

    my $id = $result->{ID};

    $job->ID($id);

    # Save this job for retrieval if the agent is restarted
    my $jobsave = $job->WORKDIR . '/job.dmp';
    open JOB, ">$jobsave" or $self->Fatal("$jobsave: $!");
    print JOB Dumper($job);
    close JOB;

    #register this job with queue monitor.
    $self->{FTS_Q_MONITOR}->QueueJob($job);
}

sub check 
{
  my ($self, $jobname, $job, $tasks) = @_;
  my ($file,$dir,$j,$f);

  $dir = $job->{$jobname}->{DIR};
  $file = $dir . '/job.dmp';
  return unless -f $file;
  $j = eval { do $file; };
  die $@ if $@; # So uncool!

# Is this job currently being monitored?
  return if $self->{FTS_Q_MONITOR}->isKnown( $j );

# $j->JOB_POSTBACK( $self->{FTS_Q_MONITOR}->JOB_POSTBACK );
# $j->FILE_POSTBACK( $self->{FTS_Q_MONITOR}->FILE_POSTBACK );
  $self->{FTS_Q_MONITOR}->QueueJob( $j );
  $self->Logmsg($j->ID,' added to monitoring');
  &touch($dir . '/live')
}

sub setup_callbacks
{
  my ($self,$kernel,$session) = @_; #[ OBJECT, KERNEL, SESSION ];

  if ( $self->{FTS_Q_MONITOR} )
  {
    $kernel->state('job_state_change',$self);
    $kernel->state('file_state_change',$self);
    my $job_postback  = $session->postback( 'job_state_change'  );
    my $file_postback = $session->postback( 'file_state_change' );
    $self->{FTS_Q_MONITOR}->JOB_POSTBACK ( $job_postback );
    $self->{FTS_Q_MONITOR}->FILE_POSTBACK( $file_postback );
  }
}

sub job_state_change
{
    my ( $self, $kernel, $arg0, $arg1 ) = @_[ OBJECT, KERNEL, ARG0, ARG1 ];
    my $job = $arg1->[0];

    # I get into this routine every time a job is monitored. Because I don't
    # want verbose monitoring forever, I turn it off here. So the first
    # monitoring call will have been verbose, the rest will not
    if ( ref($job) !~ m%PHEDEX::Transfer::Backend::Job% )
    {
$DB::single=1;
      print "I have a wrong job-type here!\n";
    }
    $job->VERBOSE(0);

    $self->Dbgmsg("Job-state callback ID ",$job->ID,", STATE ",$job->State) if $self->{DEBUG};

    if ($job->ExitStates->{$job->State}) {
    }else{
	&touch($job->Workdir."/live");
    }
}

sub file_state_change
{
  my ( $self, $kernel, $arg0, $arg1 ) = @_[ OBJECT, KERNEL, ARG0, ARG1 ];

  my $file = $arg1->[0];
  my $job  = $arg1->[1];

  $self->Dbgmsg("File-state callback TASKID ",$file->TaskID," JOBID ",$job->ID,
	  " STATE ",$file->State,' ',$file->Destination) if $self->{DEBUG};
  
  if ($file->ExitStates->{$file->State}) {
      $self->mkTransferSummary($file,$job);
  }
}

sub mkTransferSummary {
    my $self = shift;
    my $file = shift;
    my $job = shift;

    # by now we report 0 for 'Finished' and 1 for Failed or Canceled
    # where would we do intelligent error processing 
    # and report differrent erorr codes for different errors?
    my $status = $file->ExitStates->{$file->State};

    $status = ($status == 1)?0:1;
    
    my $log = join("", $file->Log,
		   "-" x 10 . " RAWOUTPUT " . "-" x 10 . "\n",
		   $job->RawOutput);

    my $summary = {START=>$file->Start,
		   END=>&mytimeofday(), 
		   LOG=>$log,
		   STATUS=>$status,
		   DETAIL=>$file->Reason || "", 
		   DURATION=>$file->Duration || 0
		   };
    
    # make a 'done' file
    &output($job->Workdir."/T".$file->{TASKID}."X", Dumper $summary);

    $self->Dbgmsg("mkTransferSummary done for task: ",$job->Workdir,' ',$file->TaskID) if $self->{DEBUG};
}

1;
