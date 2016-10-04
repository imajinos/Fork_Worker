* Copyright 2016, Yahoo Inc.
* Copyrights licensed under the New BSD License.
* See the accompanying LICENSE file for terms.

===================================================================
Fork::Worker - Fork based work management
===================================================================

Version 1.0.0
   * open sourced!

===================================================================

NAME
       Fork::Worker - Fork based work dispatch

SYNOPSIS
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

DESCRIPTION
       Fork::Worker provides simple methods for managing forked childen
       conveniently while handling the plumbing. By configuring IO::Pipe pairs
       for each child and a global lock, it support synchronization and inter-
       process communication via pipes pipes. By having the parent raise a tcp
       socket, it supports one to many work dispatch for when you just want a
       pool of workers to which you can dole out work.

       Optionally, you can use something like IPC::Lite to pull results back
       into the parent process.

       The following snippet shows how the child specific pipes can be used
       for direct communications between the parent and any particular child.

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

METHODS
   new(%options)
       new() returns a Fork::Worker object, configures a SIGCHLD handler, and
       sets up the object structure, including a tcp socket for serving work
       to child processes.

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

   start($ID)
       start() allocates a pair of IO::Pipe objects for communication, forks,
       and configures the pair for reading and writing.  Like fork(), it
       returns the child pid to the parent and 0 to the child enabling style
       like:

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

   restart(ID,CODEREF)  restart()
       restart(ID,CODEREF) is like start() except the child executes the
       passed coderef, then exits. By storing the coderef in the parent's
       object, restart() can relaunch failed children.

       restart() with no arguments allows Fork::Worker to restart any dead
       kids.  It is called this way from writework() and write(), but you can
       also call it yourself when this makes sense.

   readwork()  CHILD ONLY
       readwork() connects to the parent work management socket and reads a
       single line of input, which it returns.

       The pair of readwork() in child code and writework() in parent code is
       used when you want the parent to generate work and dispatch it to the
       spawned kids without regard for which particular kid gets which work.

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

   writework($DATA)  PARENT ONLY
       writework() accepts a single tcp connection from a child and answers it
       with $DATA $DATA should terminate with a newline

   read($ID) read()
       read() reads from a child pipe identified by the $ID value passed
       initially to start() ...when called from the parent.

       read() reads from the parent (no $ID needed) via a specific IO::Pipe
       ...when called from the child.

       Parent syntax:  while (defined $buf = $f->read($ID)) { .. } Child
       syntax:   while (defined $buf = $f->read()) { .. }

   write($ID,$DATA) write($DATA)
       write($ID,$DATA) writes $DATA to a child pipe identified by $ID (call
       from parent)

       write($DATA) writes $DATA to the parent (no $ID needed) when called
       from child

       $DATA should terminate with a newline

   print($DATA)
       print() writes $DATA to STDOUT by default or whatever filehandle has
       been selected() and uses lock/unlock to ensure the write is fully
       serialized. The locking is probably unnecessary depending on PIPEBUF
       size.

   printerr($DATA)
       printerr() writes $DATA to STDERR and uses lock/unlock to ensure the
       write is fully serialized. The locking is probably unnecessary
       depending on PIPEBUF size.

   lock()
       lock() uses flock() to get an exclusive lock on a tempfile opened by
       start() and can be used to ensure serialization of any resource used in
       the parent or children by wrapping the code to be serialized with
       lock() and unlock() calls.

   unlock()
       unlock() uses flock() to release a lock on a tempfile opened by start()
       and can be used to ensure serialization of any resource used in the
       parent or children by wrapping the code to be serialized with lock()
       and unlock() calls.

   shutdown()
       shutdown() in parent shuts down the tcp work management socket. This is
       normally called by quiesce() (which is normally called by stop()).

       readwork() in child processes will get undef at this point.

       shutdown() in child code merely closes the writer pipe back to the
       parent.

   quiesce()
       quiesce() is parent only method where we tell the kids to shut down

   wait()
       wait() is a parent only method where we wait for all kids to exit It
       should not be called before quiesce(); stop() is quiesce()->wait()

   stop() stop($RC)
       stop() is how a child should exit when work is done. It may optionally
       include a return code which is passed back to the parent. If no return
       code is passed, 0 is returned.

       stop() should also be called by the parent to indicate that you want to
       wait for the kids to exit. When called by the parent, stop will
       shutdown the work management socket and close all IO::Pipe objects
       configured to write to kids allowing kids waiting on the socket or pipe
       to detect eof or error and exit.

   reap(MAX)  => [[ PID, RC, ID ]]
       Return an reference to an array of arrays with one row for each
       completed child process and columns being PID, Return Code, and ID

       Called with optional MAX, no more than MAX rows will be returned.

       Returns empty array if kids still running and none not yet reaped.

       Returns undef when no kids are still running and all have been reaped.

       Parent my call this before or after calling stop() and may call it
       repeatedly as returned values are removed (reaped) from status table.

       After processes are reaped, get_pid, get_id, and get_rc will no longer
       return defined values when asked about reaped processes or IDs.

       Use of reap() is optional and is designed to allow parent to post-
       process as children exit.

   get_rc(PID)
       Return the return code of a completed process

   get_running()
       Return list of IDs still running

   get_running_count()
       Return the number of child processes running

   get_completed_count
       Returns the number of child processes completed but not yet reaped via
       reap()

   get_maxkids()
       Return the maxkids limit

   set_maxkids(NEWMAX)
       Set the maxkids limit when called by parent

   get_timeout
       Return the timeout value

   set_timeout(TIMEOUT)
       Set new timeout value. This can be set in parent or child but only
       effects children not yet spawned when set in parent and only effects
       the current child when called from a child

       Set to 0 for no timeout.

   get_pid(ID)
       Return the PID, given an ID. The child may have already exited. Returns
       undef when ID not recognized.

   get_id(PID)
       Return the ID, given the PID. The child may have already exitted.
       Returns undef when PID not recognized.


