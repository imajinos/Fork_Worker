#!/usr/local/bin/perl -w
#
# * Copyright 2016, Yahoo Inc.
# * Copyrights licensed under the New BSD License.
# * See the accompanying LICENSE file for terms.
#
use strict;
use Data::Dumper;
use Fork::Worker;

my $f = Fork::Worker->new(maxkids => 10);

$f->printerr("Test1: Enter a few lines, then ^D\n");

$f->start("kid1") or do {
   while (defined (my $buf = $f->read())) {
      chomp($buf);
      $f->print("Child read: $buf\n");
   }
   $f->printerr("kid1 is about to stop\n");
   $f->stop();
};

$f->start("kid2") or do {
   while (<STDIN>) {
      $f->write($_);
   }
   $f->printerr("kid2 is about to stop\n");
   $f->stop();
};

while (defined (my $buf = $f->read("kid2"))) {
   $f->write("kid1",$buf);
}
$f->printerr("main is about to stop\n");
$f->stop();

$f->printerr("Test2:\n");

my $reap1 = $f->reap();
my $reap2 = $f->reap();

$f->set_maxkids(40);
$f->set_timeout(10);

sleep 2;

foreach my $value (1..30) {
   $f->start($value) and next;
   $f->print("($$) $value\n");
   $f->stop();
}
$f->print("Stopping\n");
$f->stop();
$f->print("Stopped\n");

print Dumper(\$reap1),"\n";
print Dumper(\$reap2),"\n";

sleep 2;


# fork off 200 workers
$f = SOSE::Fork->new(maxkids=>200, timeout=>10);
$f->printerr("Test3:\n");
foreach my $id (1..200) {
   $f->start($id) or do {
      my $buf;
      while (defined($buf = $f->readwork())) {
         chomp($buf);
         $f->print("($$) aka ID: $id read $buf                 \r");
         sleep rand(2);
      }
      $f->stop();
   };
}

foreach my $work (1..500) {
  $f->writework("$work\n");
}
$f->stop();

# fork off 50 workers and use restart random deaths
$f = SOSE::Fork->new(maxkids=>110, timeout=>10);
$f->printerr("Test4:\n");
foreach my $id (1..50) {
   $f->restart($id, sub {
      srand();
      my $buf;
      while (defined($buf = $f->readwork())) {
         chomp($buf);
         sleep rand(2);
         die "($$) aka ID: $id RANDOM DEATH!\n"
            if rand()< 0.20;
      }
   });
}

foreach my $work (1..2000) {
  $f->writework("$work\n");
}
$f->stop();
