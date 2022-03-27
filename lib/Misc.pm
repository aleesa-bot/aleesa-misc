package Misc;

# Общие модули - синтаксис, кодировки итд
use 5.018; ## no critic (ProhibitImplicitImport)
use strict;
use warnings;
use utf8;
use open qw (:std :utf8);

use Clone  qw (clone);
# Модули для работы приложения
use Log::Any qw ($log);
# Чтобы "уж точно" использовать hiredis-биндинги, загрузим этот модуль перед Mojo::Redis
use Protocol::Redis::XS ();
use Mojo::Redis ();
use Mojo::IOLoop ();
use Mojo::IOLoop::Signal ();
use Data::Dumper qw (Dumper);

use Conf qw (LoadConf);

use version; our $VERSION = qw (1.0);
use Exporter qw (import);
our @EXPORT_OK = qw (RunMisc);

my $c = LoadConf ();
my $fwd_cnt = $c->{'forward_max'} // 5;

# Основной парсер
my $parse_message = sub {
	my $self = shift;
	my $m = shift;
	my $answer = clone ($m);
	$answer->{from} = 'misc';

	if (defined $answer->{misc}) {
		unless (defined $answer->{misc}->{fwd_cnt}) {
			$answer->{misc}->{fwd_cnt} = 1;
		} else {
			if ($answer->{misc}->{fwd_cnt} > $fwd_cnt) {
				$log->error ('Forward loop detected, discarding message.');
				$log->debug (Dumper $m);
				return;
			} else {
				$answer->{misc}->{fwd_cnt}++;
			}
		}

		unless (defined $answer->{misc}->{answer}) {
			$answer->{misc}->{answer} = 1;
		}

		unless (defined $answer->{misc}->{csign}) {
			$answer->{misc}->{csign} = '!';
		}
	} else {
		$answer->{misc}->{answer} = 1;
		$answer->{misc}->{csign} = '!';
		$answer->{misc}->{msg_format} = 0;
	}

	# Если сообщение не попало ни под один шаблон, оно отправляется к craniac-у
	my $send_to = 'craniac';

	$log->debug ('[DEBUG] Incoming message ' . Dumper ($m));

	# Пробуем найти команды. Сообщения, начинающиеся с $answer->{misc}->{csign}
	if (substr ($m->{message}, 0, length ($answer->{misc}->{csign})) eq $answer->{misc}->{csign}) {
		my $cmd = substr $m->{message}, length ($answer->{misc}->{csign});
		my $done = 0;

		# Вначале поищем команды модуля Phrases
		my @phrases_cmd = qw (friday пятница proverb пословица fortune фортунка f ф karma карма);

		while (my $check= pop @phrases_cmd) {
			if ($cmd eq $check) {
				$send_to = 'phrases';
				$done = 1;
				last;
			}
		}

		# Потом - команды модуля WebApp
		unless ($done) {
			my @webapp_cmd = qw (buni anek анек анекдот cat кис drink праздник fox лис frog лягушка horse лошадь лошадка
								monkeyuser rabbit bunny кролик snail улитка owl сова сыч xkcd tits boobs tities boobies
								сиси сисечки butt booty ass попа попка);

			while (my $check = pop @webapp_cmd) {
				if ($cmd eq $check) {
					$send_to = 'webapp';
					$done = 1;
					last;
				}
			}
		}

		# Потом - модуля Games
		unless ($done) {
			my @games_cmd = qw (dig копать fish fishing рыба рыбка рыбалка);

			while (my $check = pop @games_cmd) {
				if ($cmd eq $check) {
					$send_to = 'games';
					$done = 1;
					last;
				}
			}
		}

		# И наконец остальные, более сложные команды, с аргументами
		unless ($done) {
			my @cmds = ('w ', 'п ', 'weather ', 'погодка ', 'погадка ', 'погода ');

			while (my $check = pop @cmds) {
				if (length ($cmd) > length ($check)  &&  substr ($m->{message}, length ($answer->{misc}->{csign}), length ($check)) eq $check) {
					$send_to = 'webapp';
					$done = 1;
					last;
				}
			}

			$#cmds = -1;
			@cmds = ('karma ', 'карма ');

			while (my $check = pop @cmds) {
				if (length ($cmd) > length ($check)  &&  substr ($m->{message}, length ($answer->{misc}->{csign}), length ($check)) eq $check) {
					$send_to = 'phrases';
					$done = 1;
					last;
				}
			}
		}

	# Попробуем найти изменение кармы
	} elsif (substr ($m->{message}, 0 - length ('++')) eq '++'  ||  substr ($m->{message}, 0 - length ('--')) eq '--') {
		my @arr = split /\n/, $m->{message};

		# Предполагается, что фраза - это только одна строка
		if ($#arr < 1) {
			# Подпираем это дело - независимо от того, что пришло нам от chat-плагина
			$answer->{misc}->{answer} = 1;
			$send_to = 'phrases';
		}
	}

	$log->debug ("[DEBUG] Sending message to channel $send_to " . Dumper ($answer));

	$self->json ($send_to)->notify (
		$send_to => $answer,
	);

	return;
};

my $__signal_handler = sub {
	my ($self, $name) = @_;
	$log->info ("[INFO] Caught a signal $name");

	if (defined $main::pidfile && -e $main::pidfile) {
		unlink $main::pidfile;
	}

	exit 0;
};


# main loop, он же event loop
sub RunMisc {
	$log->info ("[INFO] Connecting to $c->{server}, $c->{port}");

	my $redis = Mojo::Redis->new (
		sprintf 'redis://%s:%s/1', $c->{server}, $c->{port},
	);

	$log->info ('[INFO] Registering connection-event callback');

	$redis->on (
		connection => sub {
			my ($r, $connection) = @_;

			$log->info ('[INFO] Triggering callback on new client connection');

			# Залоггируем ошибку, если соединение внезапно порвалось.
			$connection->on (
				error => sub {
					my ($conn, $error) = @_;
					$log->error ("[ERROR] Redis connection error: $error");
					return;
				},
			);

			return;
		},
	);

	my $pubsub = $redis->pubsub;
	my $sub;
	$log->info ('[INFO] Subscribing to redis channels');

	foreach my $channel (@{$c->{channels}}) {
		$log->debug ("[DEBUG] Subscribing to $channel");

		$sub->{$channel} = $pubsub->json ($channel)->listen (
			$channel => sub { $parse_message->(@_); },
		);
	}

	Mojo::IOLoop::Signal->on (
		TERM => $__signal_handler,
		INT  => $__signal_handler,
	);

	do { Mojo::IOLoop->start } until Mojo::IOLoop->is_running;
	return;
}

1;

# vim: set ft=perl noet ai ts=4 sw=4 sts=4:
