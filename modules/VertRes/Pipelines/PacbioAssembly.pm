
=head1 NAME

VertRes::Pipelines::PacbioAssembly -  Pipeline for annotating an assembly

=head1 SYNOPSIS

# make the config files, which specifies the details for connecting to the
# VRTrack g1k-meta database and the data roots:
echo '__VRTrack_PacbioAssembly__ annotation.conf' > pipeline.config
# where annotation.conf contains:
root    => '/abs/path/to/root/data/dir',
module  => 'VertRes::Pipelines::PacbioAssembly',
prefix  => '_',
 
limit => 50,
db  => {
    database => 'g1k_meta',
    host     => 'mcs4a',
    port     => 3306,
    user     => 'vreseq_rw',
    password => 'xxxxxxx',
}

data => {

}

# __VRTrack_PacbioAssembly__ 

# run the pipeline:
run-pipeline -c pipeline.config

=head1 DESCRIPTION

Pipeline for assembling pacbio data
=head1 AUTHOR

path-help@sanger.ac.uk

=cut

package VertRes::Pipelines::PacbioAssembly;

use strict;
use warnings;
use VRTrack::VRTrack;
use VRTrack::Lane;
use VRTrack::Library;
use VRTrack::Sample;
use VertRes::LSF;
use base qw(VertRes::Pipeline);
use VertRes::Utils::FileSystem;
use File::Spec;
use Utils;

our $actions = [
    {
        name     => 'pacbio_assembly',
        action   => \&pacbio_assembly,
        requires => \&pacbio_assembly_requires,
        provides => \&pacbio_assembly_provides
    },
    {
        name     => 'update_db',
        action   => \&update_db,
        requires => \&update_db_requires,
        provides => \&update_db_provides
    }
];

our %options = ( bsub_opts => '' );

sub new {
    my ( $class, @args ) = @_;

    my $self = $class->SUPER::new( %options, actions => $actions, @args );
    if ( defined( $self->{db} ) ) {
        $self->{vrtrack} = VRTrack::VRTrack->new( $self->{db} ) or $self->throw("Could not connect to the database\n");
    }
    $self->{fsu} = VertRes::Utils::FileSystem->new;

    return $self;
}

sub pacbio_assembly_provides {
    my ($self) = @_;
    return [$self->{lane_path}."/pacbio_2_2_0/contigs.fa"];
}

sub pacbio_assembly_requires {
    my ($self) = @_;
    
    my @files = glob( $self->{lane_path}."/".$self->{prefix}.'*.bax.h5');
    die 'no files to assemble' if(@files == 0);
    
    return \@files;
}

=head2 pacbio_assembly

 Title   : pacbio_assembly
 Usage   : $obj->pacbio('/path/to/lane', 'lock_filename');
 Function: Take an assembly from the assembly pipeline and automatically pacbio it.
 Returns : $VertRes::Pipeline::Yes or No, depending on if the action completed.
 Args    : lane path, name of lock file to use

=cut

sub pacbio_assembly {
    my ($self, $lane_path, $action_lock) = @_;
    
    my $memory_in_gb = $self->{memory}/1000 || 80;
    my $threads = $self->{threads} || 12;
    my $genome_size_estimate = $self->{genome_size} || 4000000;
    my $files = $self->pacbio_assembly_requires();
    my $output_dir= $self->{lane_path}."/pacbio_2_2_0";
    
      my $script_name = $self->{fsu}->catfile($lane_path, $self->{prefix}."pacbio_assembly.pl");
      open(my $scriptfh, '>', $script_name) or $self->throw("Couldn't write to temp script $script_name: $!");
      print $scriptfh qq{
  use strict;
  system("rm -rf $output_dir");
  system("pacbio_assemble_smrtanalysis --memory $memory_in_gb --threads $threads $genome_size_estimate $output_dir $files");
  system("mv $output_dir/assembly.fasta $output_dir/contigs.fa");
  system("touch $self->{prefix}pacbio_assembly_done");
  exit;
      };
      close $scriptfh;

    my $job_name = $self->{prefix}.'pacbio_assembly';
      
    $self->archive_bsub_files($lane_path, $job_name);
    VertRes::LSF::run($action_lock, $lane_path, $job_name, {bsub_opts => "-M100 -R 'select[mem>100] rusage[mem=100]'"}, qq{perl -w $script_name});

    return $self->{No};
}


=head2 update_db_requires

 Title   : update_db_requires
 Usage   : my $required_files = $obj->update_db_requires('/path/to/lane');
 Function: Find out what files the update_db action needs before it will run.
 Returns : array ref of file names
 Args    : lane path

=cut

sub update_db_requires {
    my ($self, $lane_path) = @_;
    return $self->pacbio_assembly_provides();
}

=head2 update_db_provides

 Title   : update_db_provides
 Usage   : my $provided_files = $obj->update_db_provides('/path/to/lane');
 Function: Find out what files the update_db action generates on success.
 Returns : array ref of file names
 Args    : lane path

=cut

sub update_db_provides {
   my ($self) = @_;
    return [ $self->{lane_path}."/".$self->{prefix}."pacbio_assembly_update_db_done"];
}

=head2 update_db

 Title   : update_db
 Usage   : $obj->update_db('/path/to/lane', 'lock_filename');
 Function: Records in the database that the lane has been improved.
 Returns : $VertRes::Pipeline::Yes or No, depending on if the action completed.
 Args    : lane path, name of lock file to use

=cut
sub update_db {
    my ($self, $lane_path, $action_lock) = @_;

    # all the done files are there, so just need to update the processed
    # flag in the database (if not already updated)
    my $vrlane = $self->{vrlane};
    return $$self{'Yes'} unless(defined($vrlane));
    
    my $vrtrack = $vrlane->vrtrack;
    
    return $$self{'Yes'} if $vrlane->is_processed('assembled');

    unless($vrlane->is_processed('assembled')){
      $vrtrack->transaction_start();
      $vrlane->is_processed('assembled',1);
      $vrlane->update() || $self->throw("Unable to set assembled status on lane $lane_path");
      $vrtrack->transaction_commit();
    }

    
    my $job_status =  File::Spec->catfile($lane_path, $self->{prefix} . 'job_status');
    Utils::CMD("rm $job_status") if (-e $job_status);
    
    
    my $prefix = $self->{prefix};
    # remove job files
    foreach my $file (qw(pacbio_assembly )) 
      {
        foreach my $suffix (qw(o e pl)) 
        {
          unlink($self->{fsu}->catfile($lane_path, $prefix.$file.'.'.$suffix));
        }
    }
    
    Utils::CMD("touch ".$self->{fsu}->catfile($lane_path,"$self->{prefix}pacbio_assembly_update_db_done")   );  

    return $$self{'Yes'};
}

1;

