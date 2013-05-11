package Parallel::DataPipe;

our $VERSION='0.02';
use 5.008; # Perl::MinimumVersion says that

use strict;
use warnings;
use Storable qw(freeze thaw);
use IO::Select;
use POSIX ":sys_wait_h";
use constant _EOF_ => (-(2 << 31)+1);
#use Time::HiRes;
use Data::Dumper;
use Carp;

# this should work with Windows NT or if user explicitly set that
my $number_of_cpu_cores = $ENV{NUMBER_OF_PROCESSORS}; 
sub number_of_cpu_cores {
    return $number_of_cpu_cores if $number_of_cpu_cores;
    # this works correct only in unix environment. cygwin as well.
    $number_of_cpu_cores = scalar grep m{^processor\t:\s\d+\s*$},`cat /proc/cpuinfo`;
    # otherwise it sets number_of_cpu_cores to 2
    return $number_of_cpu_cores || 2;
}

my $Sereal = eval q{use Sereal qw(encode_sereal decode_sereal);1};

my ($freeze,$thaw);

# this inits freeze and thaw with Storable subroutines and try to replace them with Sereal counterparts
sub _init_serializer {
    my $param = shift;
    if (exists $param->{freeze}) {
        ($freeze,$thaw) = map {my $c=$param->{$_};die "Parameter $_:CODE ref required" unless $c && ref($c) eq 'CODE';$c} qw(freeze thaw);
    } else {
        ($freeze,$thaw) = $Sereal?(\&encode_sereal,\&decode_sereal):(\&freeze,\&thaw);
    }
}

# init pipes and $get_data_sub, $put_data_sub
# try IO::Pipely qw(pipely);
my $pipely = $^O eq 'MSWin32' && eval "use IO::Pipely;1";
debug("Using %s pipe capabilities",$pipely?'IO::Pipely':'CORE');

my $init_pipes_sub = $pipely ?
sub { IO::Pipely::socketpairly() }
:
sub { CORE::pipe(my $ar,my $aw); CORE::pipe(my $br,my $bw); return ($br,$aw,$ar,$bw); }
;

my $get_data_sub; # get data from pipe and deserialize it
my $put_data_sub; # serialize data and put it to pipe
if ($pipely && 0) { # never use this - bug was with order of handles of socketpairly
    eval "use MIME::Base64 qw(decode_base64 encode_base64)";
    $get_data_sub = sub { my ($fh) = @_;
        #debug("expect of data ...");                 
        my $data = <$fh>;
        chomp($data);
        my $flagbyte = substr($data,0,1);
        return undef if $flagbyte eq '2'; # EOF
		my $sdata = $data; # debug only
        $data = decode_base64(substr($data,1));
		$data = $thaw->($data) if $flagbyte==1;
        #debug("got text: %s, data: %s",$sdata,$data);
        return $data;    
    };
    $put_data_sub = sub { my ($fh,$data) = @_;
        my $sdata=$data; # debug only
		my $flagbyte = "0";
        if (defined($data)) {
			if (ref($data)) {
				$flagbyte = "1";
				$data = $freeze->($data);
			}
            $data = encode_base64($data,"");
        } else {
            # put 2 as flagbyte for EOF 
            $flagbyte = 2;
            $data = "";
        }
        print $fh $flagbyte.$data."\n";
        #debug("put data: %s , text: %s.",$sdata,$flagbyte.$data);
        $fh->flush;
    };
} else {
    # this subroutine reads data from pipe and converts it to perl reference
    # or scalar - if size is negative
    # it always expects size of frozen scalar so it know how many it should read
    # to feed thaw 
    $get_data_sub = sub { my ($fh) = @_;    
        my ($data_size,$data);
        read $fh,$data_size,4;
        $data_size = unpack("l",$data_size);
        return undef if ($data_size == _EOF_);
        return  "" if $data_size == 0;
        read $fh,$data,abs($data_size);
        $data = $thaw->($data) if $data_size>0;
        #debug("get_data:%s",$data);
        return $data;
    };
    
    # this subroutine serialize data reference. otherwise 
    # it puts negative size of scalar and scalar itself to pipe.
    # it also makes flush to avoid buffering blocks execution
    $put_data_sub = sub { my ($fh,$data) = @_;
        #debug("put_data:%s",$data);
        if (!defined($data)) {
            print $fh pack("l",_EOF_);
        } elsif (ref($data)) {
            $data = $freeze->($data);
            print $fh pack("l", length($data)).$data;
        } else {
            print $fh pack("l",-length($data)).$data;        
        }
        $fh->flush();
    };
}

sub _fork_data_processor {
    my ($data_processor_callback) = @_;
    # create processor as fork
    #debug("forking...");
    # continue execution after sleep to read pipe
    my $pid = fork();
    #debug("forked pid=$pid");
    unless (defined $pid) {
        #print "say goodbye - can't fork!\n"; <>;
        die "can't fork!";
    }
    if ($pid == 0) {
        # data processor is called only in SIGALRM
        local $SIG{INT} = sub {exit;};
        local $SIG{ALRM} = $data_processor_callback;
        # and all other time it sleeps
        1 while sleep(1);
        # data processor is killed when it's not needed anymore by _kill_data_processors
        exit;
    }
    return $pid;
}

sub _create_data_processor {
    my ($process_data_callback,$fork_data_processor) = @_;
    
    my ($read_processed_data_pipe, $write_raw_data_pipe, $read_raw_data_pipe, $write_processed_data_pipe) = $init_pipes_sub->();
    
    # make closure for single-thread debug purposes
	debug("creating data processor");
    my $data_processor = sub {
        #debug("data_processor: getting data");
        local $_ = $get_data_sub->($read_raw_data_pipe);
        #debug("data_processor received value from raw pipe:%s\n",$_);
        # process data with given subroutine
        $_ = $process_data_callback->($_);
        #debug("data_processor processed value result is:%s\nPut it to <processed data> pipe",$_);
        # puts processed data back on pipe to main
        $put_data_sub->($write_processed_data_pipe,$_);
    };
    my @fork = (pid => _fork_data_processor($data_processor))  if $fork_data_processor;    
    #debug('pid of data processor:%d',$fork[1]);
    
    # return data processor record 
    return {
        @fork,                                           # pid needed to kill processor when there is no more data to process
        write_raw_data_pipe => $write_raw_data_pipe,            # pipe to write raw data from main to data processor 
        read_processed_data_pipe => $read_processed_data_pipe,  # pipe to read processed data from processor to main thread                                                                    
        is_free => 1,                                           # flag whether processor is free for processing data
                                                                # (waits for data on read_raw_data_pipe )
        data_processor => $data_processor                       # callback to subroutine which process data $_ => processed($_)
    };    
}


sub _create_data_processors {
    my ($process_data_callback,$number_of_data_processors) = @_;
    die "process_data parameter should be code ref" unless ref($process_data_callback) eq 'CODE';
    my $fork_data_processor = $number_of_data_processors > 1;
	debug("going to create %d data processors", $number_of_data_processors);
	my $processors = [map _create_data_processor($process_data_callback,$fork_data_processor), 1..$number_of_data_processors];
	debug("data processors have been created:%s",$processors);
    return $processors;
}

sub _process_data {
    my ($data,$processors) = @_;
    my @free_processors = grep $_->{is_free},@$processors;
    return 1 unless @free_processors;
    my $processor = shift(@free_processors);
    $put_data_sub->($processor->{write_raw_data_pipe},$data);
    $processor->{is_free} = 0; # now it's busy
    my $single_processor = @$processors == 1?1:0;
    if ($single_processor) {
        # debug (limited, be careful) purposes
        # execute data processor in current thread
        $processor->{data_processor}->(); 
    } else {
        # wake up child to read raw data from pipe
        #kill('SIGSTOP',$processor->{pid});
        #debug('wake up child %s to read from raw data pipe',$processor->{pid});
        kill('SIGALRM',$processor->{pid});         
    }
    # merge data if single_processor despite it's free, otherwise pipe will block
    return $single_processor; 
}

sub _receive_and_merge_data {
    my ($processors,$data_merge_code) = @_;
    
    my @busy_processors = grep $_->{is_free}==0,@$processors;
	debug("merge:found %d busy processors",scalar @busy_processors);
    
    # returns false if there is no busy processors
    return 0 unless @busy_processors;
    
    # blocking read until at least one handle is ready
	# these pipes expected to be with processed data
	my @read_processed_data_pipe = map $_->{read_processed_data_pipe},@busy_processors;
	debug('expected input for %d pipes, trying to read[0],block?',scalar @read_processed_data_pipe);
	#my $fh = $read_processed_data_pipe[0];	local $_ = <$fh>;	debug('found data : %s',$_);
	#printf("expected input for %d pipes, trying to read[0],block?\n",scalar @read_processed_data_pipe);
    @read_processed_data_pipe = IO::Select->new(@read_processed_data_pipe)->can_read(0.001);
	debug('merge found %d handles to read processed data',scalar @read_processed_data_pipe);
	#printf("merge found %d handles to read processed data\n",scalar @read_processed_data_pipe);
	return 1 unless @read_processed_data_pipe;
    for my $rh (@read_processed_data_pipe) {
        local $_ = $get_data_sub->($rh);
        #debug("merge data:%s",$_);
        $data_merge_code->($_);
		my ($processor) = grep $_->{read_processed_data_pipe} == $rh, @busy_processors;
        $processor->{is_free} = 1;
		debug('marked processor free');
    }
    
    # returns true if there was busy processors 
    return 1;        
}    
    
sub _kill_data_processors {
    my ($processors) = @_;
	return if @$processors == 1; # no forks for #==1
    my @pid_to_kill = map $_->{pid},@$processors;
    my %pid_to_wait = map {$_=>undef} @pid_to_kill;
    kill('INT',@pid_to_kill);
    while (keys %pid_to_wait) {
        my $pid = wait;
        last if $pid == -1;
        delete $pid_to_wait{$pid};
    }
}

sub _get_input_iterator {
    my $input_iterator = shift;
    unless (ref($input_iterator) eq 'CODE') {
        die "array or code reference expected for input_iterator" unless ref($input_iterator) eq 'ARRAY';
        my $array = $input_iterator;
        my $length = @$array;
        my $index = 0;
        $input_iterator = sub {
			return undef if $index >= $length;
			debug('==iterator reads %d th element: %s',$index,$array->[$index]);
			return $array->[$index++];
		};
    }
    return $input_iterator;
}

sub run {
    my $param = shift;
    
    # check if user want to use alternative serialisation routines
    _init_serializer($param);
    
    # input_iterator is either array or subroutine reference which puts data into conveyor    
    # convert it to sub ref anyway to simplify conveyor loop
    my $input_iterator = _get_input_iterator($param->{'input_iterator'});
    
    # @$processors is array with data processor info
    my $processors = _create_data_processors($param->{'process_data'},$param->{'number_of_data_processors'} || number_of_cpu_cores); 
    # data_merge is sub which merge all processed data inside parent thread
    # it is called each time after process_data returns some new portion of data    
    my $data_merge_code = $param->{'merge_data'};
    die "data_merge should be code ref" unless ref($data_merge_code) eq 'CODE';
    
    # data processing conveyor. 
	debug('starting conveyor and expect for input');
    while (defined(my $data = $input_iterator->())) {
        # _process_data returns true if all processor is busy.
        # in this case we should wait for some of them
        # using _receive_and_merge_data which waits 
        # until at least one of them put processed data to pipe for parent
        # which means it is free now
		debug("got input %s,going to process\n",$data);
         if (_process_data($data,$processors)) {
             _receive_and_merge_data($processors,$data_merge_code);
             _process_data($data,$processors) unless @$processors == 1;
         }
    }
    
    # receive and merge remaining data from parallel processors
    while (_receive_and_merge_data($processors,$data_merge_code)) {}

    # now kill & rip all data processors
    _kill_data_processors($processors);
}

1;

=head1 NAME

C<Parallel::DataPipe> - parallel data processing conveyor 

=encoding utf-8

=head1 SYNOPSIS

    use Parallel::DataPipe;
    Parallel::DataPipe::run {
        input_iterator => [1..100],
        process_data => sub { "$_:$$" },
        number_of_data_processors => 100,
        merge_data => sub { print "$_\n" },
    };
    
=head1 PORTABILITY ISSUES

This module was developed and tested under linux CentOS 6.3.
Also it was tested under cygwin.
It does NOT WORK under Windows Active Perl, sorry. 

=head1 DESCRIPTION

If you have some long running script processing data item by item (having on input some data and having on output some processed data i.e. aggregation, webcrawling,etc) here is good news for you:

You can speed it up 4-20 times with minimal efforts from you. Modern computer (even modern smartphones ;) ) have multiple CPU cores: 2,4,8, even 24! And huge amount of memory: memory is cheap now. So they are ready for parallel data processing. With this script there is an easy and flexible way to use that power.

Well, it is not the first method on parallelizm in Perl. You could write an efficient crawler using single core and framework like Coro::LWP or AnyEvent::HTTP::LWP. Also you can elegantly use all your cpu cores for parallel processing using Parallel::Loop. So what are the benefits of this module?

1) because it uses input_iterator it does not have to know all input data before starting parallel processing

2) because it uses merge_data processed data is ready for using in main thread immediately.

1) and 2) remove requirements for memory which is needed to store data items before and after parallel work. and allows parallelize work on collecting, processing and using processed data.

If you don't want to overload your database with multiple simultaneous queries
you make queries only within input_iterator and then process_data and then flush it with merge_data.
On the other hand you usually win if make queries in process_data and do a lot of data processors.
This guarantees full load of your cpu capabilities.
It's not surprise, that DB servers usually serves N queries simultaneously faster then N queries one by one.
Make tests and you will know.

To (re)write your script for using all processing power of your server you have to find out:

1) the method to obtain source/input data. I call it input iterator. It can be either array with some identifiers/urls or reference to subroutine which returns next portion of data or undef if there is nor more data to process.

2) how to process data i.e. method which receives input item and produce output item. I call it process_data subroutine. The good news is that item which is processed and then returned can be any scalar value in perl, including references to array and hashes. It can be everything that Storable can freeze and then thaw.

3) how to use processed data. I call it merge_data. In the example above it just prints an item, but you could do buffered inserts to database, send email, etc.

Take into account that 1) and 3) is executed in main script thread. While all 2) work is done in parallel forked threads. So for 1) and 3) it's better not to do things that block execution and remains hungry dogs 2) without meat to eat. So (still) this approach will benefit if you know that bottleneck in you script is CPU on processing step. Of course it's not the case for some web crawling tasks unless you do some heavy calculations

=head2 run

This is subroutine which covers magic of parallelizing data processing.
It receives paramaters with these keys via hash ref.

B<input_iterator> - reference to array or subroutine which should return data item to be processed.
    in case of subroutine it should return undef to signal EOF.

B<process_data> - reference to subroutine which process data items. they are passed via $_ variable
	Then it should return processed data. this subroutine is executed in forked process so don't
    use any shared resources inside it.
    Also you can update children state, but it will not affect parent state.

B<merge_data> - reference to a subroutine which receives data item which was processed  in $_ and now going to be merged
	this subroutine is executed in parent thread, so you can rely on changes that it made after C<process_data> completion.

These parameters are optional and has reasonable defaults, so you change them only know what you do

B<number_of_data_processors> - (optional) number of parallel data processors. if you don't specify,
    it tries to find out a number of cpu cores
	and create the same number of data processor children.
    It looks for NUMBER_OF_PROCESSORS environment variable, which is set under Windows NT.
    If this environment variable is not found it looks to /proc/cpuinfo which is availbale under Unix env.
    It makes sense to have explicit C<number_of_data_processors>
    which possibly is greater then cpu cores number
    if you are to use all slave DB servers in your environment 
    and making query to DB servers takes more time then processing returned data.
    Otherwise it's optimal to have C<number_of_data_processors> equal to number of cpu cores.

B<freeze>, B<thaw> - you can use alternative serializer. 
    for example if you know that you are working with array of words (0..65535) you can use
    freeze => sub {pack('S*',$_[0])} and thaw => sub {unpack('S*',$_[0])}
    which will reduce the amount of bytes exchanged between processes.
    But do it as the last optimization resort only.
    In fact automatic choise is quite good and efficient.
    It uses encode_sereal and decode_sereal if Sereal module is found.
    Otherwise it use Storable freeze and thaw.
=head3 How It Works

1. Main thread (parent) forks C<number_of_data_processors> of children for processing data.

2. As soon as data comes from C<input_iterator> it sends it to to next child using
serialization and pipe mechanizm.

3. Child deserialize it, process it, serialize the result and put it to pipe for parent.

4. Parent firstly fills up all the pipes to children with data and then starts to expect processed data on pipes from children.

5. If it receives data from chidlren it sends processed data to C<data_merge> subroutine,
puts new portion of unprocessed data to that childs pipe (step 2).

6. This conveyor works until input data is ended (end of C<input_iterator> array or C<input_iterator> sub returned undef).

7. In the end parent expects processed data from all busy chidlren and puts processed data to C<data_merge>

8. After having all the children sent processed data they are killed and run returns to the caller.


=head1 SEE ALSO

L<fork|http://perldoc.perl.org/functions/fork.html>

L<subs::parallel>

L<Parallel::Loops>

=head1 DEPENDENCIES

These should all be in perl's core:

 use Storable qw(freeze thaw);
 use IO::Select;
 use POSIX ":sys_wait_h";


For tests:

 use Test::More tests => 21;
 use Time::HiRes qw(time);


if found it uses Sereal module for serialization instead of Storable as it is more efficient.

=head1 BUGS 

For all bugs small and big and also what do you think about this stuff please send email to okharch@gmail.com.

=head1 SOURCE REPOSITORY

See the git source on github
 L<https://github.com/okharch/Parallel-DataPipe>

=head1 COPYRIGHT

Copyright (c) 2013 Oleksandr Kharchenko <okharch@gmail.com>

All right reserved. This library is free software; you can redistribute it
and/or modify it under the same terms as Perl itself.

=head1 AUTHOR

  Oleksandr Kharchenko <okharch@gmail.com>

=cut

sub debug {
	return;
	my $fmt= shift;
	printf STDERR "$$:$fmt\n",map ref($_)?Dumper($_):$_,@_;
}
__END__
# code to debug serializer & init_pipes stuff
use Data::Dumper;
sub test_serialize {
	my @r;
	Parallel::DataPipe::run {
	input_iterator => [[1],[3]],
	process_data => sub {$_->[0]*=2;$_},
	merge_data => sub {push @r,$_},
	number_of_data_processors => 2,
	};
	debug("r:%s",\@r);
	exit;
}
test_serialize();
sub test_get_put_data {
    my $data = [1,2,3];
    _init_serializer({});
    my ($read_processed_data_pipe, $write_raw_data_pipe, $read_raw_data_pipe, $write_processed_data_pipe) = $init_pipes_sub->();
    $put_data_sub->($write_raw_data_pipe,$data);
    my $rdata = $get_data_sub->($read_raw_data_pipe);
    #debug("received=======%s",$rdata);
}
sub test_run {
	my @r;
	Parallel::DataPipe::run {
	input_iterator => [1,3],
	process_data => sub {$_*2},
	merge_data => sub {push @r,$_},
	number_of_data_processors => 1,
	};
	debug("r:%s",\@r);
	exit;
}

