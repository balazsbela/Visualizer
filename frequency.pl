#!/usr/bin/env perl

use strict;
use warnings;

use Cwd;
use Carp;
use File::Spec;

use threads;
use threads::shared;

use SDL;
use SDL::Event;
use SDL::Events;

use SDL::Audio;
use SDL::Mixer;
use SDL::Mixer::Music;
use SDL::Mixer::Effects;
use Math::FFT;

use SDLx::App;
my $app = SDLx::App->new(
    init   => SDL_INIT_AUDIO | SDL_INIT_VIDEO,
    width  => 1366,
    height => 768,
    depth  => 32,
    title  => "Music Visualizer",
    eoq    => 1,
    dt     => 0.01,
);

my $fscreen = $ARGV[0] || 0;

if($fscreen) {
   $app->fullscreen();
}

# Initialize the Audio
unless ( SDL::Mixer::open_audio( 44100, AUDIO_S16, 2, 1024 ) == 0 ) {
    Carp::croak "Cannot open audio: " . SDL::get_error();
}

# Load our music files
my $data_dir = '.';
my @songs    = glob 'data/music/*.ogg';

my @stream_data :shared;

#  Music Effect to pull Stream Data
sub music_data {
    my ( $channel, $samples, $position, @stream ) = @_;

    {
        lock(@stream_data);
        push @stream_data, @stream;
    }

    return @stream;
}

sub done_music_data {}

my $music_data_effect_id =
  SDL::Mixer::Effects::register( MIX_CHANNEL_POST, "main::music_data",
    "main::done_music_data", 0 );

#  Music Playing Callbacks
my $current_song = 0;

my $current_music_callback = sub {
    my ( $delta, $app ) = @_;

    $app->draw_rect( [ 0, 0, $app->w(), $app->h() ], 0x000000FF );
    $app->draw_gfx_text(
        [ 5, $app->h() - 10 ],
        [ 0, 255, 0, 255 ],
        "Playing Song: " . $songs[ $current_song - 1 ]
    );

    my @stream;
    {
        lock @stream_data;
        @stream      = @stream_data;
        @stream_data = ();
    }

    # To show the right amount of lines we choose a cut of the stream
    # this is purely for asthetic reasons.

    my $N = 512;
    my $cut = $#stream / 512;    

    if($#stream < $N) { 
      return;
    }

    my $in;
    my $j = 0;
    for(my $i=0;$i<$#stream;$i+=$cut) {
	if (($cut%2 == 0) || ($i==0) ) {
	    $in -> [$j] = ($stream[$i]/2 + $stream[$i+1]/2)/256;
	    $in -> [$j+1] = 0;
	}
	else {
	    $in -> [$j] = ($stream[$i-1]/2 + $stream[$i]/2)/256;
	    $in -> [$j+1] = 0;
        }
	$j+=2;
	if($j == 1024) {
	    last;
        }
    }

    my $fft = new Math::FFT($in);    
    my $coeff = $fft -> cdft();
    my $freq;
    $j = 0;
    for(my $i=0;$i<512;$i+=2) {
	$freq -> [$j] = sqrt($coeff->[$i]*$coeff->[$i] + $coeff->[$i+1] * $coeff->[$i+1]); 	
	$j++;
    }

    my @scale = (0, 1, 2, 3, 5, 7, 10, 14, 20, 28, 40, 54, 74, 101, 137, 187, 255);
    my $val;
    my $factor = 1.0 / log(256.0);
    for(my $i = 0; $i < 16 ; $i++) {
		        my $y = 0;
			for(my $c = $scale[$i]; $c < $scale[$i + 1]; $c++) {
				if($freq->[$c] > $y) {
					$y = $freq->[$c];
			        }
			}
			$y >>= 7;
			if($y > 0) {
				$val = (log($y) * $factor);
			}
			else {
				$val = 0;
			}
			$freq->[$i] = $val;
		}


    my $red;
    my $green;
    my $blue;
    my $k = 20;
    for(my $i=0;$i < 16;$i++) {
 
	if(($i>=0) && ($i <5)) {
	    $red = 255 - ($i*$k);
	    $green = 0;
	    $blue = 0;
	}
	else {
	    if(($i>=5) && ($i<11)) {
	       $red = 0;
	       $green = 255 - ($i*$k/$i);
	       $blue = 0;
	    }
	    else {
	       $red = 0;
	       $green = 0;
	       $blue =  255 - ($i*$k/$i);
	    }
	}
	
        # Using the parameters
        #   Surface, box coordinates and color as RGBA
        SDL::GFX::Primitives::box_RGBA(
            $app,
            35 + ($i*80),
	    500-(($freq->[$i])*500),
            85+($i*80),
            500,  $red,$green,$blue, 255
        );
       
   }


  $app->flip();

};

my $cms_move_callback_id;
my $pns_move_callback_id;

my $play_next_song_callback = sub {
    return $app->stop() if $current_song >= @songs;
    my $song = SDL::Mixer::Music::load_MUS( $songs[ $current_song++ ] );

    SDL::Mixer::Music::hook_music_finished('main::music_finished_playing');
    SDL::Mixer::Music::play_music( $song, 0 );

    $app->remove_move_handler($pns_move_callback_id)
        if defined $pns_move_callback_id;

    $cms_move_callback_id = $app->add_show_handler($current_music_callback);
};

sub music_finished_playing {
    SDL::Mixer::Music::halt_music();
    $pns_move_callback_id = $app->add_move_handler($play_next_song_callback);
    $app->remove_show_handler($cms_move_callback_id);
}

$pns_move_callback_id = $app->add_move_handler($play_next_song_callback);

$app->add_event_handler(
    sub {
        my ( $event, $app ) = @_;

        if ( $event->type == SDL_KEYDOWN && $event->key_sym == SDLK_DOWN ) {

            # Indicate that we are done playing the music_finished_playing
            music_finished_playing();
        }
    }
);

$app->run();

SDL::Mixer::Effects::unregister( MIX_CHANNEL_POST, $music_data_effect_id );
SDL::Mixer::Music::hook_music_finished();
SDL::Mixer::Music::halt_music();
SDL::Mixer::close_audio();
