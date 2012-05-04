package Brightcove::common;

use strict;
use FileHandle;

use Cwd qw(abs_path getcwd);
use IO::Handle;
use File::Basename;
use Fcntl qw(:flock SEEK_END);
use File::Path qw(make_path remove_tree);

use base 'Exporter';

# Constants define behavior of various methods
# Fail on error - should sys exec calls exit the script if the command they
#                 call fails?
use constant COMMON_FAIL_ON_ERROR          => "TRUE";
use constant COMMON_CONTINUE_ON_ERROR      => "FALSE";

# Verbose output - should the output of sys exec calls be printed to
#                  the output stream
use constant COMMON_VERBOSE_OUTPUT         => "TRUE";
use constant COMMON_QUIET_OUTPUT           => "FALSE";

# Buffer output:
#     BUFFER - all output will be stored to a buffer and returned to the caller
#     UNBUFFER - all output will be printed immediately to the output stream
#                (line by line), but not returned to the caller (saves memory)
#     FLOW - all output will be printed immediately to the output stream (line
#            by line) AND stored to a buffer to be returned to the caller
use constant COMMON_BUFFER_SYS_EXEC        => "TRUE";
use constant COMMON_UNBUFFER_SYS_EXEC      => "FALSE";
use constant COMMON_FLOW_BUFFER_SYS_EXEC   => "FLOW";

# Release lock file - if a sys exec call fails, should the lock file obtained
#                     by this object also be released
use constant COMMON_AUTO_RELEASE_LOCK_FILE => "TRUE";
use constant COMMON_NO_RELEASE_LOCK_FILE   => "FALSE";

# For file/directory operations, what types of files should be considered
use constant COMMON_FILE_TYPE_ALL          => "ALL";
use constant COMMON_FILE_TYPE_FILE         => "FILE";
use constant COMMON_FILE_TYPE_DIRECTORY    => "DIRECTORY";

# Version for this commons library
use constant COMMON_VERSION                => 2.0.0;

# Perl package - what variables/methods should be exported
our $VERSION = COMMON_VERSION;
our @EXPORT_OK   = qw(
	COMMON_FAIL_ON_ERROR
	COMMON_CONTINUE_ON_ERROR
	COMMON_VERBOSE_OUTPUT
	COMMON_QUIET_OUTPUT
	COMMON_BUFFER_SYS_EXEC
	COMMON_UNBUFFER_SYS_EXEC
	COMMON_FLOW_BUFFER_SYS_EXEC
	COMMON_AUTO_RELEASE_LOCK_FILE
	COMMON_NO_RELEASE_LOCK_FILE
	COMMON_FILE_TYPE_ALL
	COMMON_FILE_TYPE_FILE
	COMMON_FILE_TYPE_DIRECTORY
	COMMON_VERSION
);
our %EXPORT_TAGS = ( COMMON_CONSTANTS => \@EXPORT_OK );

################################################################################
# Constructor
################################################################################
sub new {
	my ($class, %args) = @_;
	
	####
	# Setup the defaults for a new common object
	####
	my $scriptPath =  abs_path($0);
	$scriptPath    =~ s/[\\\/]+[^\\\/]+$//gis;
	
	my @dirStack = ();
	
	my $self  = {
		# All messages will be printed here if not changed
		OUTPUT_STREAM         => \*STDOUT,
		ERROR_STREAM          => \*STDERR,
		
		# Usage message to print if requested
		USAGE_HEADER          => "Usage: perl $0",
		
		# Absolute path to running script
		SCRIPT_PATH           => $scriptPath,
		
		# Breadcrumbs for pushd and popd
		DIR_STACK             => \@dirStack,
		
		# Script won't run unless required args are filled out
		REQUIRED_ARGUMENTS    => [],
		MIN_NAKED_ARGUMENTS   => -1,
		MAX_NAKED_ARGUMENTS   => -1,
		
		# Lock file checks - Currently may break if you try to use more than
		# one lock file
		LAST_LOCK_FILE_HANDLE => undef,
		LAST_LOCK_FILE        => undef,
		
		# Command line arguments passed in
		NAMED_ARGUMENTS  => {},
		NAKED_ARGUMENTS  => [],
		SINGLE_ARGUMENTS => {},
		
		# Default behavior if not overridden
		DEFAULTS => {
			EXEC_FAIL_ON_ERROR => COMMON_FAIL_ON_ERROR,
			EXEC_BUFFER_OUTPUT => COMMON_FLOW_BUFFER_SYS_EXEC,
			EXEC_RELEASE_LOCK  => COMMON_AUTO_RELEASE_LOCK_FILE,
			VERBOSE_OUTPUT     => COMMON_VERBOSE_OUTPUT,
			INFO_PREFIX        => "[INF] [$0] [%T] ",
			WARNING_PREFIX     => "[WRN] [$0] [%T] ",
			ERROR_PREFIX       => "[ERR] [$0] [%T] ",
			USAGE_PREFIX       => "[USE] [$0] [%T] ",
		},
	};
	
	####
	# Turn "self" into an actual object
	####
	bless($self, $class);
	
	####
	# Override any values passed in with the constructor
	####
	foreach my $arg (keys(%args)){
		$self->{$arg} = $args{$arg};
	}
	
	####
	# Parse the command line arguments
	####
	my $cmdLineArgs = parseCommandLineArgs($self, @ARGV);
	$self->{SINGLE_ARGUMENTS} = $cmdLineArgs->{SINGLE};
	$self->{NAMED_ARGUMENTS}  = $cmdLineArgs->{NORMAL};
	$self->{NAKED_ARGUMENTS}  = $cmdLineArgs->{NAKED};
	
	if(@{$self->{NAKED_ARGUMENTS}} < $self->{MIN_NAKED_ARGUMENTS}){
		$self->usage("The command line must specify at least ".$self->{MIN_NAKED_ARGUMENTS}." naked arguments.");
	}
	if($self->{MAX_NAKED_ARGUMENTS} > -1){
		if(@{$self->{NAKED_ARGUMENTS}} > $self->{MAX_NAKED_ARGUMENTS}){
			$self->usage("The command line must specify at most ".$self->{MAX_NAKED_ARGUMENTS}." naked arguments.");
		}
	}
	foreach my $arg (@{$self->{REQUIRED_ARGUMENTS}}){
		if(!defined($self->{NAMED_ARGUMENTS}->{$arg})){
			$self->usage("The command line must specify the argument --".$arg.".");
		}
	}
	
	return $self;
}

################################################################################
# Property setters/getters
################################################################################

sub getNamedArgument {
	my ($self, $argName) = @_;
	
	return $self->{NAMED_ARGUMENTS}->{$argName};
}

sub setExecOnFail {
	my ($self, $value) = @_;
	$self->{DEFAULTS}->{EXEC_ON_FAIL} = $value;
}

sub setVerboseOutput {
	my ($self, $value) = @_;
	$self->{DEFAULTS}->{VERBOSE_OUTPUT} = $value;
}

sub setInfoPrefix {
	my ($self, $value) = @_;
	$self->{DEFAULTS}->{INFO_PREFIX} = $value;
}

sub setWarningPrefix {
	my ($self, $value) = @_;
	$self->{DEFAULTS}->{WARNING_PREFIX} = $value;
}

sub setErrorPrefix {
	my ($self, $value) = @_;
	$self->{DEFAULTS}->{ERROR_PREFIX} = $value;
}

sub setUsagePrefix {
	my ($self, $value) = @_;
	$self->{DEFAULTS}->{USAGE_PREFIX} = $value;
}

################################################################################
# Print object to info stream
################################################################################
sub printObject {
	my ($self, $name, $indent, @objs) = @_;
	
	if(@objs < 1) {
		$self->info("[Print Object] No object passed in to print.");
		return;
	}
	
	if(! $indent){
		$indent = "";
	}
	if(! $name){
		$name = "(object)";
	}
	
	if(@objs > 1){
		#### A normal array (not referenced)
		$self->info($indent.$name.":\t[".(join(",", @objs))."]");
		return;
	}
	
	my $obj = $objs[0];
	my $ref = ref($obj);
	# print "(debug) ($obj) ($ref)\n";
	if(!defined($ref) || ($ref eq "")){
		#### Not a reference, just print the value
		$self->info($indent.$name.":\t".$obj);
	}
	elsif($ref eq "SCALAR"){
		#### Simple scalar - just dereference and print
		$self->info($indent.$name.":\tSCALAR:\t(".${$obj}.")");
	}
	elsif($ref eq "ARRAY"){
		#### Array reference - dereference and comma delimit the list
		$self->info($indent.$name.":\t[".(join(",", @{$obj}))."]");
	}
	elsif($ref eq "GLOB"){
		#### Not sure how to print these yet...
		$self->info($indent.$name.":\t".$obj);
	}
	else{
		#### Should either be a hash or an object
		$self->info($indent.$name.":\tHASH");
		
		eval { keys(%$obj) };
		if($@) {
			# couldn't dereference
			$self->info($indent."    (object)[".$obj."]");
		}
		else{
			foreach my $key (sort(keys(%$obj))) {
				$self->printObject($key, $indent."    ", $obj->{$key});
			}
		}
	}
}

################################################################################
# Parse command line arguments
################################################################################
sub parseCommandLineArgs {
	my ($self, @args) = @_;
	
	my $ret = {
		NORMAL => {},
		NAKED  => [],
		SINGLE => {}
	};
	
	if(!(@args)){
		@args = @ARGV;
	}
	
	my $idx=0;
	my $lastArg=$#args;
	
	while($idx <= $lastArg){
		my $arg = $args[$idx];
		
		if($arg =~ /^--(.+)$/is){
			my $key = $1;
	 		
			$idx++;
			if($idx > $lastArg){
				$self->usage("No value provided for argument $arg.");
			}
			
			if(defined($ret->{NORMAL}->{$key})){
				if(ref($ret->{NORMAL}->{$key}) ne "ARRAY"){
					my $array = [];
					push(@{$array}, $ret->{NORMAL}->{$key});
					$ret->{NORMAL}->{$key} = $array;
				}
				push(@{$ret->{NORMAL}->{$key}}, $args[$idx]);
			}
			else{
				$ret->{NORMAL}->{$key} = $args[$idx];
			}
		}
		elsif($arg =~ /^-(.+)$/is){
			my $key = $1;
			$ret->{SINGLE}->{$key} = 1;
		}
		else{
			push(@{$ret->{NAKED}}, $arg);
		}
		
		$idx++;
	}
	
	return $ret;
}

################################################################################
# Get a list of all files in a directory, and sort them by creation date
################################################################################
sub getFilesByCreationDate {
	my ($self, $baseDir, $fileType) = @_;
	
	if(!defined($fileType)){
		$fileType = COMMON_FILE_TYPE_ALL;
	}
	
	my $times = {};
	
	my @files = glob($baseDir."/*");
	foreach my $file (@files){
		if(
			($fileType eq COMMON_FILE_TYPE_ALL) ||
			( ($fileType eq COMMON_FILE_TYPE_FILE) && (-f $file) ) ||
			( ($fileType eq COMMON_FILE_TYPE_DIRECTORY) && (-d $file) )
		) {
			my ($dev,$ino,$mode,$nlink,$uid,$gid,$rdev,$size,$atime,$mtime,$ctime,$blksize,$blocks) = stat($file);
			if(!defined($times->{$ctime})){
				$times->{$ctime} = [];
			}
			push(@{$times->{$ctime}}, $file);
		}
	}
	
	my @ret = ();
	foreach my $time (sort {$a <=> $b} keys(%$times)){
		@files = @{$times->{$time}};
		foreach my $file (@files){
			push(@ret, $file);
		}
	}
	
	return @ret;
}


################################################################################
# Splits a URI into component pieces
################################################################################
sub uriSplit {
	my ($self, $uri, $defaultPort) = @_;
	
	if(!defined($defaultPort)){
		$defaultPort = 80;
	}
	
	$uri =~ m,(?:([^:/?#]+):)?(?://([^/?#]*))?([^?#]*)(?:\?([^#]*))?(?:#(.*))?,;
	my ($scheme, $auth, $path, $query, $frag) = ($1, $2, $3, $4, $5);
	
	my $origPath = $path;
	my $file = undef;
	if(defined($path)){
		my @pathParts = split(/[\\\/]/, $path);
		$file = pop(@pathParts);
		
		$path = "".(join("/", @pathParts));
	}
	
	my $origAuth = $auth;
	my ($server, $port) = (undef, undef);
	if(defined($auth)){
		if($auth =~ s/\:(\d+)$//is){
			$port = $1;
		}
		if($auth =~ /^(.+?)\:/){
			my $tmp = $1;
			$server = $auth;
			$auth = $tmp;
		}
		else{
			$server = $auth;
		}
	}
	
	if(!defined($port)){
		$port = $defaultPort;
	}
	
	my $hash = {
		SCHEME    => $scheme,
		FULL_AUTH => $origAuth,
		SERVER    => $server,
		PORT      => $port,
		FULL_PATH => $origPath,
		PATH      => $path,
		FILE      => $file,
		QUERY     => $query,
		FRAGMENT  => $frag
	};
	
	return $hash;
}

################################################################################
# Reads a file into a string
################################################################################
sub readFile {
	my ($self, $file, $encoding) = @_;
	
	my $fh = new FileHandle();
	$fh->open("<".$file) || return undef;
	if(defined($encoding)){
		binmode $fh, $encoding;
	}
	my @lines = <$fh>;
	$fh->close();
	
	return join("", @lines);
}

################################################################################
# Writes a string to a file
################################################################################
sub writeFile {
	my ($self, $string, $file, $encoding) = @_;
	
	my $fh = new FileHandle();
	$fh->open(">".$file) || return undef;
	if(defined($encoding)){
		binmode $fh, ':utf8';
	}
	$fh->print($string);
	$fh->close();
	
	return 1;
}

################################################################################
# See if a string exists in an array
################################################################################
sub inArray {
	my ($self, $element, @array) = @_;
	
	foreach my $entry (@array) {
		if($element eq $entry) {
			return 1;
		}
	}
	
	return 0;
}

################################################################################
# Search subdirectories for a file or set of files
################################################################################
sub find {
	my ($self, $dir, $pattern, $matchHash) = @_;
	
	if(!defined($matchHash)){
		$matchHash = {};
	}
	
	my @matches = glob($dir."/".$pattern);
	foreach my $match (@matches){
		my $matchPath = abs_path($match);
		$matchHash->{$matchPath} = $match;
	}
	
	my @subDirs = glob($dir."/*");
	foreach my $subDir (@subDirs){
		my $subDirPath = abs_path($subDir);
		if(-d $subDirPath){
			my $subDirMatches = $self->find($subDirPath, $pattern, $matchHash);
		}
	}
	
	return $matchHash;
}

################################################################################
# Change directory and keep track of the last directory you were in
################################################################################
sub pushd {
	my ($self, $dir) = @_;
	
	my $cwd = getcwd();
	
	if($dir !~ /^[\\\/]/){
		$dir = abs_path($cwd."/".$dir);
	}
	
	if(chdir($dir)){
		push(@{$self->{DIR_STACK}}, $cwd);
		return $dir;
	}
	$self->error("pushd to directory '".$dir."' failed.");
	return undef;
}

################################################################################
# Change directory back to the last directory you were in before calling pushd
################################################################################
sub popd {
	my ($self) = @_;
	
	my @dirStack = @{$self->{DIR_STACK}};
	if(@dirStack){
		my $lastDir = pop(@dirStack);
		if(chdir($lastDir)){
			$self->{DIR_STACK} = \@dirStack;
			return $lastDir;
		}
		$self->error("popd failed to change to directory '".$lastDir."'.");
		return undef;
	}
	$self->error("popd can't change directory - empty directory stack.");
}

################################################################################
# Delete a path on the file system
################################################################################
sub deletePath{
	my ($self, $path) = @_;
	
	my $verbose = 0;
	if($self->{DEFAULTS}->{VERBOSE_OUTPUT} eq COMMON_VERBOSE_OUTPUT){
		$verbose = 1;
	}
	
	remove_tree($path, {verbose => $verbose});
}

################################################################################
# Create a path on the file system
################################################################################
sub createPath{
	my ($self, $path, $permissions) = @_;
	
	my $verbose = 0;
	if($self->{DEFAULTS}->{VERBOSE_OUTPUT} eq COMMON_VERBOSE_OUTPUT){
		$verbose = 1;
	}
	
	if(defined($permissions)){
		make_path($path, {verbose => 1, mode => $permissions});
	}
	else{
		make_path($path, {verbose => 1});
	}
}

################################################################################
# Execute a command via the shell
################################################################################
sub sysExec {
	my ($self, $command, $failOnError, $verboseOutput, $bufferOutput, $releaseLockFile) = @_;
	
	# Warning - this isn't safe for un-checked input.  It
	# can allow arbitraty code to run from $command,
	# which could be a very bad thing...
	
	if(!defined($failOnError)){
		$failOnError = $self->{DEFAULTS}->{EXEC_FAIL_ON_ERROR};
	}
	if(!defined($verboseOutput)){
		$verboseOutput = $self->{DEFAULTS}->{VERBOSE_OUTPUT};
	}
	if(!defined($bufferOutput)){
		$bufferOutput = $self->{DEFAULTS}->{EXEC_BUFFER_OUTPUT};
	}
	if(!defined($releaseLockFile)){
		$releaseLockFile = $self->{DEFAULTS}->{EXEC_RELEASE_LOCK};
	}
	
	if($verboseOutput eq COMMON_VERBOSE_OUTPUT){
		$self->info("Executing command '$command'.");
		
		my $cwd = getcwd();
		$self->info("    CWD: '$cwd'");
	}
	
	my $exitCode = undef;
	my $buffer   = undef;
	my $fh       = new FileHandle();
	
	if($bufferOutput eq COMMON_BUFFER_SYS_EXEC){
		$fh = new FileHandle();
		$fh->open("$command 2>&1 |");
		$buffer = "".(join("", <$fh>))."";
		$fh->close();
		
		$exitCode = $? >> 8;
		
		if($verboseOutput eq COMMON_VERBOSE_OUTPUT){
			$self->info("Command '$command' completed with exit code $exitCode.  Command output:\n$buffer");
		}
	}
	else{
		my $bufferSetting = $|;
		$buffer = "";
		$fh->open("$command 2>&1 |");
		while(my $line = <$fh>){
			my $outputLine = $line;
			$outputLine =~ s/\r*\n+//gis;
			$self->info("    [command output] $outputLine");
			if($bufferOutput eq COMMON_FLOW_BUFFER_SYS_EXEC){
				$buffer .= $line;
			}
		}
		$fh->close();
		$exitCode = $? >> 8;
		$| = $bufferSetting;
		
		if($verboseOutput eq COMMON_VERBOSE_OUTPUT){
			$self->info("Command '$command' completed with exit code $exitCode.");
		}
	}
	
	if($exitCode != 0){
		$self->error("Command '$command' failed with non-zero exit code ($exitCode)");
		
		if($releaseLockFile eq COMMON_AUTO_RELEASE_LOCK_FILE){
			$self->releaseLockFile();
		}
		if($failOnError eq COMMON_FAIL_ON_ERROR){
			die "Exiting from Sys Exec errors.\n";
		}
	}
	
	return($exitCode, $buffer);
}

################################################################################
# Redirect standard output and standard error to a log file
################################################################################
sub redirectOutputToLog {
	my ($self, $filePrefix, $filePostfix) = @_;
	
	my ($filestamp, $timestamp) = $self->genTimeStamp();
	my $logFile = $filePrefix.$filestamp.$filePostfix;
	$self->redirectStdOut($logFile, "TRUE");
	$self->redirectStdErr($logFile, "FALSE");
}

################################################################################
# Redirect standard output to a file
################################################################################
sub redirectStdOut {
	my ($self, $file, $overwrite) = @_;
	
	if(!defined($overwrite)){
		$overwrite = "FALSE";
	}
	
	my $fh      = new FileHandle();
	my $success = 1;
	if($overwrite =~ /^TRUE$/i){
		$fh->open(">".$file) || ($success = 0);
	}
	else{
		$fh->open(">>".$file) || ($success = 0);
	}
	if(!$success){
		$self->error("Couldn't open file '$file' to redirect STDOUT: $!");
		return undef;
	}
	
	STDOUT->fdopen($fh, 'w') || ($success = 0);
	if(!($success)){
		$self->error("Couldn't redirect STDOUT to '$file': $!");
		return undef;
	}
	
	STDOUT->autoflush(1);
	$fh->autoflush(1);
	
	$self->info("STDOUT redirected to '$file'");
	return $fh;
}

################################################################################
# Redirect standard error to a file
################################################################################
sub redirectStdErr {
	my ($self, $file, $overwrite) = @_;
	
	if(!defined($overwrite)){
		$overwrite = "FALSE";
	}
	
	my $fh      = new FileHandle();
	my $success = 1;
	if($overwrite =~ /^TRUE$/i){
		$fh->open(">".$file) || ($success = 0);
	}
	else{
		$fh->open(">>".$file) || ($success = 0);
	}
	if(!$success){
		$self->error("Couldn't open file '$file' to redirect STDERR: $!");
		return undef;
	}
	
	STDERR->fdopen($fh, 'w') || ($success = 0);
	if(!($success)){
		$self->error("Couldn't redirect STDERR to '$file': $!");
		return undef;
	}
	
	STDERR->autoflush(1);
	$fh->autoflush(1);
	
	$self->info("STDERR redirected to '$file'");
	return $fh;
}

################################################################################
# Acquire a lock file atomically
################################################################################
sub acquireLockFile {
	my ($self, $lockFile, $quiet) = @_;
	
	if(!defined($quiet)){
		$quiet = 0;
	}
	
	if(!defined($lockFile)){
		$self->error("Asked to lock file, but no filename provided.");
		return undef;
	}
	
	if(! $quiet){
		$self->info("Acquiring lock file '$lockFile'.");
	}
	
	my $fh      = new FileHandle();
	my $success = 1;
	$fh->open(">".$lockFile)      || ($success = 0);
	if(!$success){
		$self->error("Couldn't open lock file '$lockFile': $!");
		return undef;
	}
	flock($fh, LOCK_EX | LOCK_NB) || ($success = 0);
	if(!$success){
		$self->error("Couldn't acquire flock on lock file '$lockFile': $!");
		return undef;
	}
	seek($fh, 0, SEEK_END)        || ($success = 0);
	if(!$success){
		$self->error("Couldn't seek on lock file '$lockFile' - this means someone else appended while we were waiting for flock");
		return undef;
	}
	
	my @months = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
	my @weekDays = qw(Sun Mon Tue Wed Thu Fri Sat Sun);
	my ($second, $minute, $hour, $dayOfMonth, $month, $yearOffset, $dayOfWeek, $dayOfYear, $daylightSavings) = localtime();
	my $year = 1900 + $yearOffset;
	my $timestamp = "$hour:$minute:$second, $weekDays[$dayOfWeek] $months[$month] $dayOfMonth, $year";
	$fh->print("Lock file requested by $0 at $timestamp.\n");
	
	$self->{LAST_LOCK_FILE_HANDLE} = $fh;
	$self->{LAST_LOCK_FILE}        = $lockFile;
	
	if(! $quiet){
		$self->info("Acquired lock file '$lockFile'.");
	}
	return $fh;
}

################################################################################
# Release a lock file
################################################################################
sub releaseLockFile {
	my ($self, $lockFile, $quiet) = @_;
	
	if(!defined($quiet)){
		$quiet = 0;
	}
	
	my $lockFileHandle = undef;
	if(defined($lockFile)){
		$lockFileHandle = new FileHandle();
		$lockFileHandle->open(">>".$lockFile);
	}
	else{
		$lockFile = $self->{LAST_LOCK_FILE};
		$lockFileHandle = $self->{LAST_LOCK_FILE_HANDLE};
	}
	
	if(!defined($lockFileHandle)){
		$self->error("Asked to unlock file, but no file handle provided.");
		return undef;
	}
	
	if(! $quiet){
		$self->info("Releasing lock file '$lockFile'.");
	}
	
	my $success = 1;
	flock($lockFileHandle, LOCK_UN) || ($success = 0);
	if(!$success){
		$self->error("Couldn't release lock file '$lockFile': $!");
		return undef;
	}
	
	# Technically a small chance this could delete someone else's lock file...
	my $delete = unlink($lockFile);
	if(! $delete){
		$self->warning("Couldn't delete lock file '$lockFile': $!");
		$self->warning("Lock will still be released, but file will be present.");
	}
	
	if(! $quiet){
		$self->info("Released lock on file '$lockFile'.");
	}
	return $lockFileHandle;
}

################################################################################
# Generate a file stamp
################################################################################
sub genTimeStamp {
	my ($self) = @_;
	
	my @months   = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
	my @weekDays = qw(Sun Mon Tue Wed Thu Fri Sat Sun);
	
	my ($second, $minute, $hour, $dayOfMonth, $monthOffset, $yearOffset, $dayOfWeek, $dayOfYear, $daylightSavings) = localtime();
	
	my $year  = 1900 + $yearOffset;
	my $month = 1 + $monthOffset;
	if($second     < 10) { $second     = "0".$second; }
	if($minute     < 10) { $minute     = "0".$minute; }
	if($hour       < 10) { $hour       = "0".$hour;   }
	if($dayOfMonth < 10) { $dayOfMonth = "0".$dayOfMonth; }
	
	my $timestamp = $year."_".$months[$monthOffset]."_".$dayOfMonth."__".$hour."_".$minute."_".$second."__".$daylightSavings;
	
	my $timestampReadable = "$hour:$minute:$second, $weekDays[$dayOfWeek] $months[$monthOffset] $dayOfMonth, $year";
	
	return($timestamp, $timestampReadable, $year, $month, $dayOfMonth, $hour, $minute, $second, $daylightSavings);
}

################################################################################
# Append all jar files in a directory to the environment classpath
################################################################################
sub searchDirForJarFiles {
	my ($self, $dir) = @_;
	
	my $osname = $^O;
	my $envSep = ":";
	if(($osname eq 'MSWin32') || ($osname =~ /^WinXP/i)){
		$envSep = ";";
	}
	
	my @newFiles = glob($dir."/*.jar");
	if($ENV{CLASSPATH}){
		push(@newFiles, $ENV{CLASSPATH});
	}
	my $newCP = join($envSep, @newFiles);
	$ENV{CLASSPATH} = $newCP;
	
	return @newFiles;
}

################################################################################
# Read in a config file
################################################################################
# A custom/simple configuration file format:
#   one variable per line
#   variable name and value separated by = sign (only first = sign is used)
#   whitespace before/after = sign is stripped
#   hash tag defines a comment
sub readConfigFile {
	my ($self, $file) = @_;
	
	my $conf = {};
	
	my $fh = new FileHandle();
	$fh->open("<".$file) || return undef;
	my @lines = <$fh>;
	$fh->close();
	
	foreach my $line (@lines){
		$line =~ s/\r*\n+//gis;
		$line =~ s/\#.*$//gis;
		
		if($line =~ /^(.+?)=(.*)$/){
			my ($key, $val) = ($1, $2);
			$key =~ s/\s+$//gis;
			$val =~ s/^\s+//gis;
			
			if(defined($conf->{$key})){
				if(ref($conf->{$key}) eq "ARRAY"){
					push(@{$conf->{$key}}, $val);
				}
				else{
					$conf->{$key} = [$conf->{$key}, $val];
				}
			}
			else{
				$conf->{$key} = $val;
			}
		}
	}
	
	return $conf;
}

################################################################################
# Print an error message
################################################################################
sub error {
	my ($self, $message, $indent) = @_;
	
	if(!($indent)){
		$indent = "";
	}
	
	my $prefix = $self->{DEFAULTS}->{ERROR_PREFIX};
	
	my ($timestamp, $timestampReadable, @rest) = $self->genTimeStamp();
	$prefix =~ s/\%t/$timestamp/gs;
	$prefix =~ s/\%T/$timestampReadable/gs;
	
	foreach my $line (split(/\r*\n+/, $message)){
		$self->{ERROR_STREAM}->print($prefix.$indent.$line."\n");
	}
}

################################################################################
# Print an informational message
################################################################################
sub info {
	my ($self, $message, $indent) = @_;
	
	if(!($indent)){
		$indent = "";
	}
	
	my $prefix = $self->{DEFAULTS}->{INFO_PREFIX};
	
	my ($timestamp, $timestampReadable, @rest) = $self->genTimeStamp();
	$prefix =~ s/\%t/$timestamp/gs;
	$prefix =~ s/\%T/$timestampReadable/gs;
	
	foreach my $line (split(/\r*\n+/, $message)){
		$self->{OUTPUT_STREAM}->print($prefix.$indent.$line."\n");
	}
}

################################################################################
# Print a warning message
################################################################################
sub warning {
	my ($self, $message, $indent) = @_;
	
	if(!($indent)){
		$indent = "";
	}
	
	my $prefix = $self->{DEFAULTS}->{WARNING_PREFIX};
	
	my ($timestamp, $timestampReadable, @rest) = $self->genTimeStamp();
	$prefix =~ s/\%t/$timestamp/gs;
	$prefix =~ s/\%T/$timestampReadable/gs;
	
	foreach my $line (split(/\r*\n+/, $message)){
		$self->{ERROR_STREAM}->print($prefix.$indent.$line."\n");
	}
}

################################################################################
# Print a banner message
################################################################################
sub printBanner {
	my ($self, $message, $token, $width) = @_;
	
	my $leftOver = $width - length($message) - 2;
	my $left  = $leftOver / 2;
	my $right = $leftOver / 2;
	if($leftOver % 2 != 0){
		$left  -= 0.5;
		$right += 0.5;
	}
	if($left < 1){
		$left = 1;
	}
	if($right < 1){
		$right = 1;
	}
	
	$self->info("".($token x $width)."");
	$self->info("".($token x $left)." ".$message." ".($token x $right)."");
	$self->info("".($token x $width)."");
}

################################################################################
# Print a usage message and exit
################################################################################
sub usage {
	my ($self, $message, $exitCode) = @_;
	
	if(!defined($exitCode)){
		$exitCode = 1;
	}
	
	my $prefix = $self->{DEFAULTS}->{USAGE_PREFIX};
	
	my ($timestamp, $timestampReadable, @rest) = $self->genTimeStamp();
	$prefix =~ s/\%t/$timestamp/gs;
	$prefix =~ s/\%T/$timestampReadable/gs;
	
	foreach my $line (split(/\r*\n+/, $self->{USAGE_HEADER})){
		$self->{ERROR_STREAM}->print($prefix.$line."\n");
	}
	foreach my $line (split(/\r*\n+/, $message)){
		$self->{ERROR_STREAM}->print($prefix."    ".$line."\n");
	}
	
	exit($exitCode);
}

1;
