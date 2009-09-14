=head1 NAME

VertRes::Wrapper::GATK - wrapper for Broad's GenomeAnalysisToolKit

=head1 SYNOPSIS

use VertRes::Wrapper::GATK;

my $wrapper = VertRes::Wrapper::GATK->new(recalibrate => 1);

# run something with the toolkit
$wrapper->count_covariates('in.bam', 'in.bam');
$wrapper->table_recalibration('in.bam', 'in.bam.recal_data.csv', 'out.bam');

# or for your convienience:
$wrapper->recalibrate('in.bam', 'out.bam');

# check the status
my $status = $wrapper->run_status;
if ($status == -1) {
    # try and run it again?...
}

=head1 DESCRIPTION

Ostensibly a wrapper for Broad's GenomeAnalysisToolKit, this is primarily
focused on using it to recalibrate the quality values in bam files. See:
http://www.broadinstitute.org/gsa/wiki/index.php/Quality_scores_recalibration

For mouse, assumes you have the env variable MOUSE pointing to team145's mouse
directory.

=head1 AUTHOR

Sendu Bala: bix@sendu.me.uk

=cut

package VertRes::Wrapper::GATK;

use strict;
use warnings;
use Cwd qw (abs_path);
use File::Basename;
use File::Spec;
use File::Copy;

use base qw(VertRes::Wrapper::WrapperI);
use VertRes::Wrapper::samtools;

our $DEFAULT_GATK_JAR = File::Spec->catfile($ENV{BIN}, 'GenomeAnalysisTK.jar');
our $DEFAULT_REFERENCE = File::Spec->catfile($ENV{G1K}, 'ref', 'broad_recal_data', 'human_b36_both.fasta');
our $DEFAULT_DBSNP = File::Spec->catfile($ENV{G1K}, 'ref', 'broad_recal_data', 'dbsnp_129_b36.rod');
our $DEFAULT_LOGLEVEL = 'ERROR';

=head2 new

 Title   : new
 Usage   : my $wrapper = VertRes::Wrapper::GATK->new();
 Function: Create a VertRes::Wrapper::GATK object.
 Returns : VertRes::Wrapper::GATK object
 Args    : quiet => boolean
           exe   => string (full path to GenomeAnalysisTK.jar; a TEAM145 default
                            exists)
           reference => ref.fa (path to reference fasta; can be overriden in
                                individual methods with the R option; a TEAM145
                                default exists for human G1K project)
           dbsnp    => snp.rod (path to dbsnp rod file; can be overriden in
                                individual methods with the DBSNP option; a
                                TEAM145 default exists for human G1K project)
           log_level => DEBUG|INFO|WARN|ERROR|FATAL|OFF (set the log level;
                                can be overriden in individual methods with the
                                l option; default 'ERROR')

=cut

sub new {
    my ($class, @args) = @_;
    
    my $self = $class->SUPER::new(exe => $DEFAULT_GATK_JAR, @args);
    
    $self->exe('java -Xmx4000m -jar '.$self->exe);
    
    # our bsub jobs will get killed if we don't select high-mem machines
    $self->bsub_options(M => 4000000, R => "'select[mem>4000] rusage[mem=4000]'");
    
    # default settings
    $self->{_default_R} = delete $self->{reference} || $DEFAULT_REFERENCE;
    $self->{_default_DBSNP} = delete $self->{dbsnp} || $DEFAULT_DBSNP;
    $self->{_default_loglevel} = delete $self->{log_level} || $DEFAULT_LOGLEVEL;
    
    return $self;
}

sub _handle_common_params {
    my ($self, $params) = @_;
    
    unless (defined $params->{R}) {
        $params->{R} = $self->{_default_R};
    }
    unless (defined $params->{DBSNP}) {
        $params->{DBSNP} = $self->{_default_DBSNP};
    }
    unless (defined $params->{l}) {
        $params->{l} = $self->{_default_loglevel};
    }
}

=head2 count_covariates

 Title   : count_covariates
 Usage   : $wrapper->count_covariates('input.bam', 'output_prefix');
 Function: Generates a file necessary for recalibration. Will create first
           input.bam.bai using samtools index if it doesn't already exist.
 Returns : n/a
 Args    : path to input .bam file, path to output file (which will have its
           name suffixed with '.recal_data.csv'). Optionally, supply R, DBSNP,
           or l options (as a hash), as understood by GATK.

=cut

sub count_covariates {
    my ($self, $in_bam, $out_csv, @params) = @_;
    
    # java -Xmx2048m -jar GenomeAnalysisTK.jar \
    #   -R resources/Homo_sapiens_assembly18.fasta \
    #   --DBSNP resources/dbsnp_129_hg18.rod \
    #   -l INFO \
    #   -T CountCovariates \ 
    #   -I my_reads.bam \
    #   --OUTPUT_FILEROOT my_reads.recal_data.csv
    
    $self->switches([qw(quiet_output_mode)]);
    $self->params([qw(R DBSNP l T)]);
    
    my @file_args = (" -I $in_bam", " --OUTPUT_FILEROOT $out_csv");
    
    my %params = @params;
    $params{T} = 'CountCovariates';
    $params{quiet_output_mode} = $self->quiet();
    $self->_handle_common_params(\%params);
    
    $self->register_output_file_to_check($out_csv);
    $self->_set_params_and_switches_from_args(%params);
    
    return $self->run(@file_args);
}

=head2  table_recalibration

 Title   : table_recalibration
 Usage   : $wrapper->table_recalibration('in.bam', 'recal_data.csv', 'out.bam');
 Function: Recalibrates a bam using the csv file made with count_covariates().
 Returns : n/a
 Args    : path to input .bam file, path to output file. Optionally, supply R
           or l options (as a hash), as understood by GATK.

=cut

sub table_recalibration {
    my ($self, $in_bam, $csv, $out_bam, @params) = @_;
    
    # java -Xmx2048m -jar GenomeAnalysisTK.jar \
    #   -l INFO \ 
    #   -R resources/Homo_sapiens_assembly18.fasta \ 
    #   -T TableRecalibration \
    #   -I my_reads.bam \
    #   -outputBAM my_reads.recal.bam \
    #   -params my_reads.recal_data.csv
    
    $self->switches([qw(quiet_output_mode)]);
    $self->params([qw(R l T)]);
    
    my @file_args = (" -I $in_bam", " -outputBAM $out_bam", " -params $csv");
    
    my %params = @params;
    $params{T} = 'TableRecalibration';
    $params{params} = $csv;
    $params{quiet_output_mode} = $self->quiet();
    $self->_handle_common_params(\%params);
    
    $self->register_output_file_to_check($out_bam);
    $self->_set_params_and_switches_from_args(%params);
    
    return $self->run(@file_args);
}

=head2 recalibrate

 Title   : recalibrate
 Usage   : $wrapper->recalibrate('input.bam', 'out.bam');
 Function: Easy-to-use recalibration. Just runs count_covariates() followed by
           table_recalibration(). Also ensures the output bam isn't truncated.
           Won't attempt to recalibrate if out.bam already exists.
 Returns : n/a
 Args    : path to input .bam file, path to output file. Optionally, supply R,
           DBSNP, or l options (as a hash), as understood by GATK.

=cut

sub recalibrate {
    my ($self, $in_bam, $out_bam, @params) = @_;
    
    my $orig_run_method = $self->run_method;
    $self->run_method('system');
    
    # count_covariates
    my $csv = $in_bam.".recal_data.csv";
    unless (-s $csv) {
        $self->count_covariates($in_bam, $in_bam, @params);
        $self->throw("failed during the count_covariates step, giving up for now") unless $self->run_status >= 1;
    }
    
    # table_recalibration
    unless (-s $out_bam) {
        my $tmp_out = $out_bam;
        $tmp_out =~ s/\.bam$/.tmp.bam/;
        $self->table_recalibration($in_bam, $csv, $tmp_out, @params);
        $self->throw("failed during the table_recalibration step, giving up for now") unless $self->run_status >= 1;
        
        # find out how many lines are in the input bam file
        my $st = VertRes::Wrapper::samtools->new(quiet => 1);
        $st->run_method('open');
        my $bam_count = 0;
        my $fh = $st->view($in_bam);
        while (<$fh>) {
            $bam_count++;
        }
        close($fh);
        
        # find out how many lines are in the recalibrated bam file
        my $recal_count = 0;
        $fh = $st->view($tmp_out);
        while (<$fh>) {
            $recal_count++;
        }
        close($fh);
        
        # check for truncation
        if ($recal_count >= $bam_count) {
            move($tmp_out, $out_bam) || $self->throw("Failed to move $tmp_out to $out_bam: $!");
            $self->_set_run_status(2);
        }
        else {
            $self->warn("$tmp_out is bad (only $recal_count lines vs $bam_count), will unlink it");
            $self->_set_run_status(-1);
            unlink($tmp_out);
        }
    }
    
    $self->run_method($orig_run_method);
    return;
}

sub _pre_run {
    my $self = shift;
    $self->_set_params_string(mixed_dash => 1);
    
    my $input_bam = $_[0];
    $input_bam =~ s/^ -I //;
    my $bai_file = $input_bam.'.bai';
    
    # check that the bai is older than the bam
    if (-e $bai_file && $self->_is_older($input_bam, $bai_file)) {
        unlink($bai_file);
    }
    
    # create a bai file if necessary
    unless (-e $bai_file) {
        my $sam_wrapper = VertRes::Wrapper::samtools->new(verbose => $self->verbose,
                                                          run_method => 'system');
        $sam_wrapper->index($input_bam, $bai_file);
        
        unless ($sam_wrapper->run_status >= 1) {
            if ($sam_wrapper->run_status == -1) {
                $self->warn("Failed to create index file '$bai_file', will try one more time and then give up...");
                sleep(5);
                $sam_wrapper->index($input_bam, $bai_file);
            }
            unless ($sam_wrapper->run_status >= 1) {
                $self->throw("Failed to create index file '$bai_file', giving up!");
            }
        }
    }
    
    return @_;
}

sub run {
    my $self = shift;
    
    # refuses to be quiet, so force the issue
    if ($self->quiet) {
        my $run_method = $self->run_method;
        $self->run_method('open');
        my ($fh) = $self->_run(@_);
        while (<$fh>) {
            next;
        }
        close($fh);
        $self->_post_run();
        $self->run_method($run_method);
    }
    else {
        return $self->SUPER::run(@_);
    }
}

sub _post_run_old {
    my $self = shift;
    
    # check the output
    $self->_set_run_status(1);
    my $output_bam = $self->{_outbam};
    if (-e $output_bam) {
        # on true success, RecalQual creates an index of the output bam
        my $out_index = $output_bam;
        $out_index .= '.bai';
        unless (-s $out_index) {
            $self->_set_run_status(-1);
        }
        
        if ($self->evaluate()) {
            # .png file should have been created; we know its dir location,
            # but the file name is strange
            my $dir_name = basename($self->{_inbam});
            $dir_name =~ s/\.[^.]+$//;
            $dir_name = "$self->{_output_dir}/output.$dir_name/";
            my $png_file = `ls $dir_name/recalibrated.*.empirical_v_reported_quality.png`;
            unless ($png_file) {
                $self->_set_run_status(-1);
            }
        }
    }
    else {
        $self->_set_run_status(0);
    }
    
    return @_;
}

1;
