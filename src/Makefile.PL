#
# * Copyright 2016, Yahoo Inc.
# * Copyrights licensed under the New BSD License.
# * See the accompanying LICENSE file for terms.
#

use Config; 
use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.

my $NAME = "Fork_Worker";
my $PLATFORM_MAJOR = `yinst platform PLATFORM_MAJOR`;
chomp($PLATFORM_MAJOR);

my %WriteMakefileArgs = (
    'NAME'	=> "Fork::Worker",
    'VERSION_FROM'	=> "lib/Fork/Worker.pm", # finds $VERSION
    'PREREQ_PM'	=> {}, # e.g., Module::Name => 1.1
    'ABSTRACT_FROM' => "lib/Fork/Worker.pm", # retrieve abstract from module
    'DEFINE'	=> "",
    'INC'	=> "-I/home/y/include",
($PLATFORM_MAJOR eq "rhel.4.x") ? (
    'LIBS'	=> ["-L/home/y/lib -lyfor"],
    'CCFLAGS'	=> "-shared -m32 $Config{ccflags}",
    'LDDLFLAGS' => "-shared -m32 $Config{ldflags} $Config{cccdlflags}",
) : (
    'LD'	=> "/usr/bin/gcc",
    'LIBS'	=> ["-L/home/y/lib64 -lyfor"],
    'CCFLAGS'	=> "-shared -m64 $Config{ccflags}",
    'LDDLFLAGS' => "-shared -m64 $Config{ldflags} $Config{cccdlflags}",
)
);

WriteMakefile(%WriteMakefileArgs);
