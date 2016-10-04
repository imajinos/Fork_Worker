#
# * Copyright 2016, Yahoo Inc.
# * Copyrights licensed under the New BSD License.
# * See the accompanying LICENSE file for terms.
#

# Fork::Worker - Fork Based Work dispatch

# who we are and who we use. All modules are in standard unix perl release
package Fork::Worker;
use strict;
use IO::Pipe;
use IO::Handle;
use File::Temp;
use Fcntl ':flock'; 
use Carp qw(croak);
use IO::Socket::INET;
use POSIX ":sys_wait_h";

=head1 NAME

Fork::Worker - Fork based work dispatch

=cut

=head1 SYNOPSIS

   use Fork::Worker;
   my $f = Fork::Worker->new();

   # Fork 30 new kids and have them print their pid and ID value
   foreach my $id (1..30) {
      $f->start($id) and next;
      $f->print("($$) $id\n");
      $f->stop();
   }
   $f->print("Stopping\n");
   $f->stop();
   $f->print("Stopped\n");

=cut

=head1 DESCRIPTION

Fork::Worker provides simple methods for managing forked childen conveniently while
handling the plumbing. By configuring IO::Pipe pairs for each child and a global
lock, it support synchronization and inter-process communication via pipes
pipes. By having the parent raise a tcp socket, it supports one to many work
dispatch for when you just want a pool of workers to which you can dole out work.

Optionally, you can use something like IPC::Lite to pull results back into
the parent process.

The following snippet shows how the child specific pipes can be used for
direct communications between the parent and any particular child.

   use Fork::Worker;
   my $f = Fork::Worker->new();

   # fork kid1 to read from the parent and report to STDOUT
   $f->start("kid1") or do {
      while (defined (my $buf = $f->read())) {
         chomp($buf);
         $f->print("kid1 read: $buf\n");
      }
      $f->printerr("kid1 is about to stop\n");
      $f->stop();
   };

   # fork kid2 to read from STDIN and write to the parent
   $f->start("kid2") or do {
      while (<STDIN>) {
         $f->write($_);
      }
      $f->printerr("kid2 is about to stop\n");
      $f->stop();
   };

   # Meanwhile, parent reads from kid2 and writes to kid1
   while (defined (my $buf = $f->read("kid2"))) {
      $f->write("kid1",$buf);
   }
   $f->printerr("parent is about to stop\n");
   $f->stop();

=cut

=head1 METHODS

=head2 new(%options)

new() returns a Fork::Worker object, configures a SIGCHLD handler, 
and sets up the object structure, including a tcp socket for
serving work to child processes.

There are two options that may be passed:

   "maxkids" sets the tcp listen queue size and maximum number
             of processes allowed to run simultaneously
             Default is 40

   "timeout" sets the alarm() timeout used by child processes
             when reading from the parent via read or readwork
             Default is no timeout (0, undef, unspecified)

    my $f = Fork::Worker(maxkids => 10, timeout => 60);
    my $f = Fork::Worker(maxkids => 80);

If you get really strange results or hangs, see if they go away when
you reduce the number of kids. You may be over-driving your system.

=cut

sub new {
   # instantiate
   my $s = {}; my $class = shift; my %parms = @_; bless $s, $class;

   # configure   
   $s->{_lock} = File::Temp->new();
   $s->{_maxkids} = $parms{maxkids} || 40;
   $s->{_timeout} = $parms{timeout} || 0;
   $s->{_pstable} = {};
   $s->{_identity} = {};
   $s->{_pids2id} = {};
   $s->{_status} = {};
   $s->{_pipes} = {};
   $s->{_child} = 0;
   $s->{_parent} = $$;
   $s->{_died} = {};

   # work managment socket
   $s->{_work} = IO::Socket::INET->new(
      Listen => $s->{_maxkids},
      LocalHost => '127.0.0.1',
      Proto => 'tcp',
      Reuse => 1,
   ) or die "Error $! with socket creation\n";

   # setup child handler
   $s->{_CHLD} = sub {
      while ((my $child = waitpid(-1,WNOHANG)) > 0) {
         $s->{_status}->{$child} = $?;
         delete $s->{_pstable}->{$child};
         delete $s->{_pipes}->{$child};
         my $id = $s->{_pid2id}->{$child};
         if (defined($id) and defined($s->{_coderef}->{$id})) {
            $s->{_died}->{$id}=1; 
         }
      }
   };
   $SIG{CHLD} = $s->{_CHLD};

   return $s;
}

=head2 start($ID)

start() allocates a pair of IO::Pipe objects for communication,
forks, and configures the pair for reading and writing.
Like fork(), it returns the child pid to the parent and 0 to the
child enabling style like:

    $f->start($ID) or do {
       CHILD stuff here
       $f->stop();
    };

   or

   foreach my $work (@WORK) {
      $f->start($work) and next;
      CHILD stuff here..
      $f->stop();
   }

   Parent continues here

=cut
  
sub start {
   my $s = shift;
   my $id = shift;

   # I consider this a fatal error. Plan your family size
   croak "Cannot start from child!" if $s->{_child};
   if (keys %{$s->{_pstable}} >= $s->{_maxkids}) {
      $s->stop();
      croak "Max kids, ".$s->{_maxkids}.", exceeded";
   }

   # reader and writer here is from parent point of view
   $s->{_pipes}->{$id}->{reader} = IO::Pipe->new();
   $s->{_pipes}->{$id}->{writer} = IO::Pipe->new();

   # ensure stdio autoflushed
   STDERR->autoflush(1);
   STDOUT->autoflush(1);
   
   # fork or throw fatal error. fork returns child PID and 0
   #  to parent and new child process, respectively
   my $pid = fork();
   die "Cannot fork $!\n" if ! defined $pid;
 
   # Parent notes new child and configures pipes for it
   if ($pid) {
      $s->{_pstable}->{$pid} = $id;
      $s->{_pid2id}->{$pid} = $id;
      $s->{_identity}->{$id} = $pid;
      $s->{_status}->{$pid} = undef;
      $s->{_pipes}->{$id}->{reader}->reader();
      $s->{_pipes}->{$id}->{writer}->writer();
      $s->{_pipes}->{$id}->{writer}->autoflush(1);

   # Child configures other end of pipes and embraces youth
   } else {
      $s->{reader} = $s->{_pipes}->{$id}->{writer};
      $s->{writer} = $s->{_pipes}->{$id}->{reader};
      $s->{reader}->reader();
      $s->{writer}->writer()->autoflush(1);
      $s->{_child} = 1; 

      # if restart() passed a coderef, child exits here
      if (defined($s->{_coderef}->{$id})) {
         &{$s->{_coderef}->{$id}}();
         exit;
      }
   }

   # else both parent and child return the fork return value
   return $pid;
}

=head2 restart(ID,CODEREF)  restart()

restart(ID,CODEREF) is like start() except the child executes the passed 
coderef, then exits. By storing the coderef in
the parent's object, restart() can relaunch failed children.

restart() with no arguments allows Fork::Worker to restart any dead kids.
It is called this way from writework() and write(), but you can also
call it yourself when this makes sense.

=cut

sub restart {
   my ($s,$id,$coderef) = (shift,shift,shift);
   
   # handle specific call
   if (defined($id) and defined($coderef)) {
      $s->{_coderef}->{$id} = $coderef;
      return $s->start($id);
   }

   # handle ad-hoc call
   return $s unless defined $s->{_coderef};
   my @dead_ids = keys %{ $s->{_died} };
   return $s unless @dead_ids;
   foreach my $id (@dead_ids) {
      delete $s->{_died}->{$id}; # reap it
      next unless exists $s->{_coderef}->{$id};
      $s->restart($id, $s->{_coderef}->{$id});
   } 
   return $s;
}

=head2 readwork()  CHILD ONLY

readwork() connects to the parent work management socket and reads
a single line of input, which it returns.

The pair of readwork() in child code and writework() in parent code
is used when you want the parent to generate work and dispatch it
to the spawned kids without regard for which particular kid gets
which work.

   # fork 200 child workers and have them print what they got
   my $f = Fork::Worker->new(maxkids=>200);
   foreach my $id (1..200) {
      $f->restart($id, sub {

         # the coderef is executed by a new child process
         while (defined(my $buf = $f->readwork())) {
            chomp($buf);
            $f->print("($$) aka ID: $id read $buf\n");
            sleep rand(2);
         }

         # for kids, this is really just exit()
         $f->stop(); # redundant since Fork::Worker::restart adds one
      });
   }

   # parent generates 5000 lines of input for forked kids
   foreach my $work (1..5000) {
     $f->writework("$work\n");
   }

   # for the parent, this is shutdown socket (not used in this example),
   #  close pipes, and wait for kids. it does not exit
   $f->stop(); # 

=cut

sub readwork {
   my $s = shift;
   if ($s->{_child}) {
      my $psocket = $s->{_work};
      my $server_addr = '127.0.0.1';
      my $server_port = $psocket->sockport();
      my $socket = undef;
      my %sock_cfg = (
            PeerHost => $server_addr,
            PeerPort => $server_port,
            Proto => 'tcp',
      );
      $sock_cfg{Timeout} = $s->{_timeout} if $s->{_timeout};
      eval { $socket = IO::Socket::INET->new(%sock_cfg) };
      return undef unless defined $socket;
      alarm($s->{_timeout}) if $s->{_timeout};
      my $data = undef;
      eval { $data = <$socket> };
      alarm(0) if $s->{_timeout};
      return $data;
   }
   croak "Cannot call readwork from parent!";
}

=head2 writework($DATA)  PARENT ONLY

writework() accepts a single tcp connection from a child and answers it with $DATA
$DATA should terminate with a newline

=cut

sub writework {
   my $s = shift;
   my $data = shift;
   croak "Cannot call writework from child!" if $s->{_child};
   my $socket = $s->{_work};
   my $client_socket = undef;
   while (1) { 
      $client_socket = $socket->accept();
      last if defined $client_socket;
   }
   my $peer_addr = $socket->peerhost();
   my $peer_port = $socket->peerport();
   $client_socket->send($data);
   $client_socket->shutdown(2);
   $s->restart(); # restart a dead kid, if any
   return $s;
}

=head2 read($ID) read()

read() reads from a child pipe identified by the $ID value passed initially to
start() ...when called from the parent.

read() reads from the parent (no $ID needed) via a specific IO::Pipe 
...when called from the child.

Parent syntax:  while (defined $buf = $f->read($ID)) { .. }
Child syntax:   while (defined $buf = $f->read()) { .. }

=cut

sub read {
   my $s = shift;
   my $id = shift;
   my $r = undef;
   if ($s->{_child}) {
      $r = $s->{reader};
      return undef if eof($r);
      alarm($s->{_timeout}) if $s->{_timeout};
      my $data = undef;
      eval { $data = <$r> };
      alarm(0) if $s->{_timeout};
      return $data;
   }
   croak "Cannot call read without children!" unless scalar keys %{$s->{_pstable}};
   croak "Id $id not found!" unless exists $s->{_pipes}->{$id}->{reader};
   $r = $s->{_pipes}->{$id}->{reader};
   return undef if eof($r);
   return <$r>;
}

=head2 write($ID,$DATA) write($DATA)

write($ID,$DATA) writes $DATA to a child pipe identified by $ID (call from parent)

write($DATA) writes $DATA to the parent (no $ID needed) when called from child

$DATA should terminate with a newline

=cut

sub write {
   my $s = shift;
   my $id = shift; # child passes DATA here
   my $data = shift; # child passes nothing here
   my $w = undef;
   if ($s->{_child}) {
      $w = $s->{writer};
      print $w $id; # actually, child is writing the passed DATA
      return $s;
   }
   croak "Cannot call write without children!" unless scalar keys %{$s->{_pstable}};
   croak "Id $id not found!" unless exists $s->{_pipes}->{$id}->{writer};
   $w = $s->{_pipes}->{$id}->{writer};
   print $w $data;
   $s->restart();
   return $s;
}

=head2 print($DATA)

print() writes $DATA to STDOUT by default or whatever filehandle has been selected()
and uses lock/unlock to ensure the write is fully serialized. The locking is
probably unnecessary depending on PIPEBUF size.

=cut

sub print {
   my $s = shift;
   my $data = shift;
   $s->lock();
   print $data;
   return $s->unlock();
}

=head2 printerr($DATA)

printerr() writes $DATA to STDERR and uses lock/unlock to ensure the write is fully 
serialized. The locking is probably unnecessary depending on PIPEBUF size.

=cut

sub printerr {
   my $s = shift;
   my $data = shift;
   $s->lock();
   print STDERR $data;
   return $s->unlock();
}
      
=head2 lock()

lock() uses flock() to get an exclusive lock on a tempfile opened by start() and
can be used to ensure serialization of any resource used in the parent or 
children by wrapping the code to be serialized with lock() and unlock() calls.

=cut

sub lock   { my $s = shift; flock($s->{_lock}, LOCK_EX); return $s}

=head2 unlock()

unlock() uses flock() to release a lock on a tempfile opened by start() and
can be used to ensure serialization of any resource used in the parent or 
children by wrapping the code to be serialized with lock() and unlock() calls.

=cut

sub unlock { my $s = shift; flock($s->{_lock}, LOCK_UN); return $s}

=head2 shutdown()

shutdown() in parent shuts down the tcp work management socket. This is
normally called by quiesce() (which is normally called by stop()).

readwork() in child processes will get undef at this point.

shutdown() in child code merely closes the writer pipe back to the
parent.

=cut

sub shutdown {
   my $s = shift;

   # child mode
   if ($s->{_child}) {
      close($s->{writer}) unless defined($s->{_writer_shutdown});
      $s->{_writer_shutdown} = 1;
      return $s;
   }

   # parent mode
   $s->{_work}->shutdown(2) unless defined($s->{_work_shutdown});
   $s->{_work_shutdown} = 1;
   return $s;
}

=head2 quiesce()

quiesce() is parent only method where we tell the kids to shut down

=cut

sub quiesce {
   my $s = shift;
   croak "Do not call quiesce() from child\n" if $s->{_child};
   $s->shutdown();
   foreach my $id (keys %{ $s->{_pipes} } ) {
      close($s->{_pipes}->{$id}->{writer});
   }
   return $s;
}

=head2 wait() 

wait() is a parent only method where we wait for all kids to exit
It should not be called before quiesce(); stop() is quiesce()->wait()

=cut

sub wait {
   my $s = shift;
   croak "Do not call wait() from child\n" if $s->{_child};
   while (1) {
      last if scalar keys %{ $s->{_pstable} } == 0;
      select(undef,undef,undef,0.1);
   }
   return $s;
}


=head2 stop() stop($RC)

stop() is how a child should exit when work is done. It may optionally include
a return code which is passed back to the parent. If no return code is passed,
0 is returned.

stop() should also be called by the parent to indicate that you want to wait
for the kids to exit. When called by the parent, stop will shutdown the work
management socket and close all IO::Pipe objects configured to write to kids
allowing kids waiting on the socket or pipe to detect eof or error and exit.

=cut

sub stop {
   my $s = shift;
   my $rc = shift||0;
   exit $rc if $s->{_child};
   return $s->quiesce()->wait();
}

=head2 reap(MAX)  => [[ PID, RC, ID ]]

Return an reference to an array of arrays with one row for each 
completed child process and columns being PID, Return Code, and ID

Called with optional MAX, no more than MAX rows will be returned.

Returns empty array if kids still running and none not yet reaped.

Returns undef when no kids are still running and all have been reaped.

Parent my call this before or after calling stop() and may call it
repeatedly as returned values are removed (reaped) from status table.

After processes are reaped, get_pid, get_id, and get_rc will no longer
return defined values when asked about reaped processes or IDs.

Use of reap() is optional and is designed to allow parent to
post-process as children exit. 

=cut

sub reap {
   my $s = shift;
   my $maxrows = shift||0;
   my @return = ();
   croak "Do not call reap() from child process!" if $s->{_child};
   return undef if 0==$s->get_running_count() and 0==$s->get_completed_count();
   return \@return if 0==$s->get_completed_count();
   my @reaped = ();
   foreach my $pid (keys %{ $s->{_status}}) {
      push(@return, [ $pid, $s->get_rc($pid), $s->get_id($pid) ]);
      push(@reaped,$pid);
      last if $maxrows and $maxrows <= @return;
   }
   foreach my $pid (@reaped) { 
      my $id = $s->get_id($pid);
      delete $s->{_status}->{$pid};
      delete $s->{_pid2id}->{$pid};
      delete $s->{_identity}->{$id}; 
   }
   return \@return;
}
      
   
=head2 get_rc(PID)

Return the return code of a completed process

=cut

sub get_rc {
   my $s=shift;
   my $pid = shift;
   return undef unless defined $pid;
   return undef unless exists $s->{_status}->{$pid};
   return $s->{_status}->{$pid};
}

=head2 get_running()

Return list of IDs still running

=cut

sub get_running {
   my $s = shift;
   my @running_pids = keys %{ $s->{_pstable} };
   my @running_ids = grep { defined($_) } map { $s->get_id($_) } @running_pids;
   return wantarray ? @running_ids : "@running_ids";
}

=head2 get_running_count()

Return the number of child processes running

=cut

sub get_running_count { my $s=shift; return scalar keys %{ $s->{_pstable}} }

=head2 get_completed_count

Returns the number of child processes completed but not yet reaped via reap()

=cut

sub get_completed_count { my $s=shift; return scalar keys %{ $s->{_status}} }

=head2 get_maxkids()

Return the maxkids limit

=cut

sub get_maxkids { my $s=shift; return $s->{_maxkids} }

=head2 set_maxkids(NEWMAX)

Set the maxkids limit when called by parent

=cut

sub set_maxkids { my $s=shift; $s->{_maxkids} = $1 if $_[0] =~ /^(\d+)$/; return $s}

=head2 get_timeout 

Return the timeout value

=cut

sub get_timeout { my $s=shift; return $s->{_timeout} }

=head2 set_timeout(TIMEOUT)

Set new timeout value. This can be set in parent or child but only
effects children not yet spawned when set in parent and only effects
the current child when called from a child

Set to 0 for no timeout.

=cut

sub set_timeout { my $s=shift; $s->{_timeout} = $1 if $_[0] =~ /^(\d+)$/; return $s }

=head2 get_pid(ID)

Return the PID, given an ID. The child may have already exited. Returns
undef when ID not recognized.

=cut

sub get_pid { 
   my ($s,$id) = (shift,shift);
   return undef unless defined $id;
   return undef unless exists $s->{_identity}->{$id};
   return $s->{_identity}->{$id};
}

=head2 get_id(PID)

Return the ID, given the PID. The child may have already exitted. Returns
undef when PID not recognized.

=cut

sub get_id {
   my ($s,$pid) = (shift,shift);
   return undef unless defined $pid;
   return undef unless exists $s->{_pid2id}->{$pid};
   return $s->{_pid2id}->{$pid};
}



# end of module. return true.
1;

__END__
