use strict;

package PHC::Event;
{
	use base 'AppCore::DBI';
	
	use ThemePHC::Groups; 
	
	__PACKAGE__->meta(
	{
		@Boards::DbSetup::DbConfig,
		table	=> 'events',
		
		schema	=> 
		[
			{ field => 'eventid',			type => 'int', @AppCore::DBI::PriKeyAttrs },
			{ field	=> 'groupid',			type => 'int',	linked => 'PHC::Group' },
			{ field	=> 'contact_userid',		type => 'int',	linked => 'AppCore::User' },
			{ field => 'contact_name',		type => 'varchar(255)' },
			{ field => 'contact_email',		type => 'varchar(255)' },
			{ field	=> 'event_text',		type => 'text' },
			{ field	=> 'page_details',		type => 'text' },
			{ field => 'is_weekly',			type => 'int(1)'},
			{ field	=> 'datetime',			type => 'datetime'},
			{ field	=> 'end_time',			type => 'time' },
			{ field => 'show_endtime',		type => 'int(1)', null=>0, default=>0 },
			{ field => 'weekday',			type => 'int'},
			{ field => 'at_phc',			type => 'int(1)'},
			{ field => 'location',			type => 'text'},
			{ field => 'location_map_link',		type => 'text'},
			{ field	=> 'postid',			type => 'int',	linked => 'Boards::Post' },
			{ field => 'fake_folder_override',	type => 'int' },
			{ field => 'deleted',			type => 'int' },
		],	
	});
	
	#__PACKAGE__->add_constructor(by_group => 'groupid=? and deleted!=1 order by is_weekly, datetime');
}

package ThemePHC::Events;
{
	# Inherit both the Boards and Page Controller.
	# We use the Page::Controller to register a custom
	# 'Board' page type for user-created board pages  
	use base qw{
		Boards
		Content::Page::Controller
	};
	
	use Content::Page;
	use AppCore::Common;
	
	# This 'Boards' subclass is rather simple. As may know, Boards functions something like this:
	# 
	# [List of Groups (Board::Groups)] ->
	#	[Each Group has a Collection of Boards (Boards::Board)] -> 
	#		[Each Board has Collection of Posts (Boards::Post)] -> 
	#			[Posts have Comments (Boards::Post with top_commentid set)]
	#
	# This subclass just uses a single 'Boards::Board' to keep all its events within as 
	# specially crafted Boards::Posts (each PHC::Event (above) corresponds to a single Boards::Post).
	#
	# We maintain a decorator table outside of Boards::Post instead of using the user-data
	# functions in Boards::Post::data() because we want to be able to use SQL to query for
	# date ranges and other arbitrary queries for events. Since the 'data' field in Boards::Posts
	# is stored as a JSON string in a 'text' field, queries against that are very risky in terms
	# of reliability. It's much cleaner to just query against specific columns in PHC::Events,
	# then do join in SQL or even just in perl to get the corresponding Boards::Post object.
	#
	# Boards::Posts aren't strictly necessary - we could have written this Events module without 
	# subclassing Boards at all. However, it does provide us with the commenting functionality
	# and takes care of spam filtering. Additionally, building on an existing module just keeps
	# us from having to worry about *all* the details. Additionally, by maintining appropriatly
	# rendered Boards::Post objects, we get 'Activity Log' and 'Search' support for free. 
	#
	# Once we do this module "right", we'll use a similar subclass arragement (with misc changes)
	# for the Pastors Blog, Ask Pastor, Video, and Audio recording modules.
	#
	
	# Register our pagetype
	__PACKAGE__->register_controller('PHC Events Database','PHC Events page, calendar, etc',1,0);  # 1 = uses page path,  0 = doesnt use content
	
	use Data::Dumper;
	use DateTime;
	use AppCore::Common;
	use JSON qw/to_json/;
	
	my $MGR_ACL = [qw/EventsManager/];
	
	my $BOARD_FOLDER = 'events';
	
	my $SUBJECT_LENGTH = 50;
	
	my $EVENTS_BOARD = Boards::Board->by_field(title=>'Events');
	
	my @DOW_NAMES = qw/- Monday Tuesday Wednesday Thursday Friday Saturday Sunday/;
	my @DOW_NAMES_SHORT = qw/- Mon Tue Wed Thur Fri Sat Sun/;
	my @DOW_LETTERS = qw/- M T W R F S S/;
	my @MONTH_NAMES = qw/January Feburary March April May June July August September October November December/;
	my @MONTH_NAMES_SHORT = qw/Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec/;
	
	sub apply_mysql_schema
	{
		my $self = shift;
		my @db_objects = qw{
			PHC::Event
		};
		AppCore::DBI->mysql_schema_update($_) foreach @db_objects;
	}
	
	sub new
	{
		my $class = shift;
		
		my $self = bless {}, $class;
		
		$self->config(); # setup default config
		$self->apply_config(
		{
			short_noun	=> 'Events',
			long_noun	=> 'Events',
			
			# TODO figure out which templates we want to override
			main_tmpl	=> 'events/main.tmpl',
			new_post_tmpl	=> 'events/new_post.tmpl',
			list_tmpl	=> 'events/list.tmpl',
			post_tmpl	=> 'events/post.tmpl',
			
			
			post_reply_tmpl	=> 'boards/post_reply.tmpl',
			edit_forum_tmpl	=> 'boards/edit_forum.tmpl',
			
			admin_acl	=> [qw/EventsManager Admin-WebBoards Pastor/],
			
			#new_post_tmpl	=> 'pages/events/new_post.tmpl',
			#post_tmpl	=> 'pages/events/post.tmpl',
			#post_reply_tmpl	=> 'pages/boards/post_reply.tmpl',
			
			
		});
		
		return $self;
	};
		
	# Board page is everything we do - it's the listing of events - the main page
	# We'll also provide an "alternate view" - a calendar page
	
	sub board_page
	{
		my $class = shift;
		my ($req,$r,$board) = @_;
		
		my $sub_page = $req->next_path;
		if($sub_page eq 'new' || $sub_page eq 'post')
		{
			my $can_admin = 1 if ($_ = AppCore::Web::Common->context->user) && $_->check_acl($MGR_ACL);
			return $r->error("Not Allowed","Sorry, you're not allowed to post in here.") if !$can_admin;
		}
		## XXX TODO
		elsif(!$sub_page || ($sub_page eq 'events' && !$req->next_path(1)))
		{
			return $class->basic_view($req,$r);
		}
		
		# Not needed now
		#$req->shift_path if $sub_page eq 'events';
		if($sub_page eq 'events')
		{
			$req->shift_path;
			return $r->redirect($class->binpath .'/'. $req->next_path); 
		}
		#die Dumper $req;
		
		return $class->SUPER::board_page($req,$r,$board);
	}
	
	sub new_post_hook
	{
		my $self = shift;
		my $tmpl = shift;
		my $board = shift;
		$tmpl->param(event_at_phc => 1);
		$tmpl->param(hr_12 => 1);
		$tmpl->param(date => (split /\s/, date())[0]);
		$tmpl->param(group_list => PHC::Group->tmpl_select_list(undef,1));
	}
	
# 	sub load_post 
# 	{
# 		my $class = shift;
# 		my ($post,$section_name,$board_folder_name) = @_;

	sub load_post#($post,$req,$dont_count_view||0,$more_local_ctx||undef);
	{
		my $self = shift;
		
		my ($post) = @_;
		
		my $rs = $self->SUPER::load_post(@_);
		
		# Apply text changes here
		#$rs->{post_text} = $tmpl->output;
		
		my $x = PHC::Event->retrieve($post->data->get('itemid'));
		#die Dumper $post->data, $x if !$x;
		#die Dumper $post;
		$rs->{type_event} = 1;
		if($x)
		{
			$rs->{'event_'.$_} = $x->get($_) foreach $x->columns;
		}	
		
		$post->{item} = $x;
		$self->prep_event_hash($post);
		
		foreach my $prep_key (qw/time same_day day_name normal_datestamp timestamp end_time/)
		{
			$rs->{$prep_key} = $post->{$prep_key};
		}
		
		if($x->groupid && $x->groupid->id && $x->groupid->folder_name && ($x->datetime cmp date()) > 0)
		{
			return AppCore::Web::Common::redirect('/connect/groups/'.$x->groupid->folder_name);
		}
	
		return $rs;
	}
	
	sub load_post_edit_form
	{
		my $class = shift;
		my $post = shift;
		
		my $rs = $class->SUPER::load_post_edit_form($post);
		
		#$rs->{
		
		#my $hash = $post->data->hash;
		#$rs->{'data_'.$_} = $hash->{$_} foreach keys %$hash;
		
		# Load appros data to edit the item based on $post->data->type
		
		my $x = PHC::Event->retrieve($post->data->get('itemid'));
		$rs->{type_event} = 1;
		$rs->{'event_'.$_} = $x->get($_) foreach $x->columns;
		$rs->{'dow'.$x->weekday} = 1;
		
		my ($date,$time) = split/\s/, $x->datetime;
		$rs->{date} = $date;
		
		my ($hr,$min,$sec) = split/:/, $time;
		$rs->{'hr_'.($hr+0)} = 1;
		$rs->{min} = $min;
		
		my ($end_hr,$end_min) = split/:/, $x->end_time;
		$rs->{'hr2_'.($end_hr+0)} = 1;
		$rs->{end_min} = $end_min;
		
		$rs->{group_list} = PHC::Group->tmpl_select_list($x->groupid,1);
		
		#die Dumper $rs;
		
		return $rs;
	}
	
	
	sub create_new_thread
	{
		my $self = shift;
		my $board = shift;
		my $args = shift;
		
		#my $filename = $args->{upload};
		#PHC::Web::Skin->error("No Filename Given","You must specify a file to upload.")if !$filename;
		
		if(!$args->{subject})
		{
			$args->{subject} = $self->guess_subject($args->{comment});
		}
		
		#die Dumper ($args);
			
		# TODO implement
		#$self->import_uploaded_image($post,$filename,'upload');
		
		# - Figure out if they're adding a news item or event
		# - add appros object to database
		# - set $post->data->type and $post->data->itemid 
		# - redirect to main page
		
		if($args->{is_weekly} eq 'yes')
		{
# 			my @split = split/\s/, $args->{datetime};
# 			shift @split if @split == 2;
# 			$args->{datetime} = '0000-00-00 '.(shift @split);
		}
		
		$args->{date} = '0000-00-00' if !$args->{date};
                $args->{end_hour} = '00' if !$args->{end_hour};
                $args->{end_min} = '00' if !$args->{end_min};
                $args->{min} = '00' if !$args->{min};
                $args->{hour} = '12' if !$args->{hour};

                $args->{datetime} = $args->{date}.' '.$args->{hour}.':'.rpad($args->{min}).':00';
                $args->{end_time} = $args->{end_hour}.':'.rpad($args->{end_min}).':00';

                $args->{subject} = $args->{event_text};
                $args->{comment} =
                        ($args->{is_weekly} ?
                                ('Every '.$DOW_NAMES[$args->{weekday}].' at '.$args->{hour}.':'.$args->{min}) :
                                ($args->{datetime}.($args->{show_endtime} ? "-$args->{end_time}":""))
                        ).' - '.$args->{subject};
	
		#$args->{datetime} = $args->{date}.' '.$args->{hour}.':'.$args->{min}.':00';
		#$args->{end_time} = $args->{end_hour}.':'.$args->{end_min}.':00';
		
		#$args->{comment} = $args->{datetime}.($args->{show_endtime} ? "-$args->{end_time}":"").' - '.$args->{subject};  
		
		my $post = $self->SUPER::create_new_thread($board,$args);
		
		my $ref = {
			postid		=> $post->id,
			contact_userid	=> AppCore::User->by_field(email => $args->{contact_email}),
			event_text	=> $args->{subject},
			is_weekly	=> $args->{is_weekly} eq 'yes' ? 1:0,
			datetime	=> $args->{datetime},
			end_time	=> $args->{end_time},
			show_endtime	=> $args->{show_endtime} ?1:0,
			weekday		=> $args->{weekday},
			page_details	=> $args->{page_details},
			contact_email	=> $args->{contact_email},
			contact_name	=> $args->{contact_name},
			groupid		=> $args->{groupid},
			at_phc		=> $args->{at_phc} eq 'yes' ? 1:0,
			location	=> $args->{location},
			location_map_link => $args->{map_link},
		};
		
		#die Dumper $ref, $post, $args;
		
		my $x = PHC::Event->create($ref);
		
		#$post->data->set('type','event'); # TODO is this still needed?
		$post->data->set('itemid',$x->id);
		$post->data->update;
		
		# TODO revise this
# 		if($args->{alert_flag})
# 		{
# 			my $flag = $args->{alert_flag};
# 			my %flags = qw/red 3000 yellow 2000 green 1000/;
# 
# 			$post->ticker_priority($flags{$flag});
# 			$post->ticker_class($flag.'-alert');
# 			$post->update;
# 		}
		
		
		print STDERR "Created event $x, postid $post\n";
		return $post;
	}
	
	sub post_edit_save
	{
		my $self = shift;
		my $post = shift;
		my $args = shift;
		
		
		$args->{date} = '0000-00-00' if !$args->{date};
		$args->{end_hour} = '00' if !$args->{end_hour};
		$args->{end_min} = '00' if !$args->{end_min};
		$args->{min} = '00' if !$args->{min};
		$args->{hour} = '12' if !$args->{hour};
		
		$args->{datetime} = $args->{date}.' '.$args->{hour}.':'.rpad($args->{min}).':00';
		$args->{end_time} = $args->{end_hour}.':'.rpad($args->{end_min}).':00';
		
		$args->{subject} = $args->{event_text};
		$args->{comment} = 
			($args->{is_weekly} ? 
				('Every '.$DOW_NAMES[$args->{weekday}].' at '.$args->{hour}.':'.$args->{min}) : 
				($args->{datetime}.($args->{show_endtime} ? "-$args->{end_time}":""))
			).' - '.$args->{subject};
		
		#die Dumper $args;
		
		$self->SUPER::post_edit_save($post,$args);
		
# 		if($args->{fake_folder_override} eq 'yes')
# 		{
# 			my $text = AppCore::Web::Common->html2text($args->{subject_override});
# 			$text =~ s/[\r\n]/ /g;
# 					
# 			# limit the length only to the width of the sql field, no arbitrary limits here :-)
# 			my $new_subject = substr($text,0,250). (length($text) > 250 ? '...' : '');;
# 			$post->subject($new_subject) if $post->subject ne $new_subject;
# 			#die Dumper $new_subject;
# 			
# 		
# 			my $fake_it = $self->to_folder_name($post->subject);
# 			if($fake_it ne $post->folder_name && Boards::Post->by_field(folder_name => $fake_it))
# 			{
# 				$fake_it .= '_'.$post->id;
# 			}
# 			
# 			#die "overriding folder name to [$fake_it]";
# 			
# 			$post->folder_name($fake_it) if $fake_it ne $post->folder_name;
# 			
# 			$post->update if $post->is_changed;
# 			
# 		}
		
		if($args->{is_weekly} eq 'yes')
		{
# 			my @split = split/\s/, $args->{datetime};
# 			shift @split if @split == 2;
# 			$args->{datetime} = '0000-00-00 '.(shift @split);
		}
		
		
		my $x = PHC::Event->retrieve($post->data->get('itemid'));
		
		$x->contact_userid(		AppCore::User->by_field(email => $args->{contact_email}));
		$x->contact_email(		$args->{contact_email});
		$x->contact_name(		$args->{contact_name});
		$x->groupid(			$args->{groupid});
		$x->end_time(			$args->{end_time});
		$x->show_endtime(		$args->{show_endtime});
		$x->event_text(			$args->{event_text});
		$x->page_details(		$args->{page_details});
		$x->is_weekly(			$args->{is_weekly} eq 'yes' ? 1:0);
		$x->fake_folder_override(	$args->{fake_folder_override} eq 'yes' ? 1:0);
		$x->datetime(			$args->{datetime});
		$x->weekday(			$args->{weekday});
		$x->at_phc(			$args->{at_phc} eq 'yes' ? 1:0);
		$x->location(			$args->{location});
		$x->location_map_link(		$args->{map_link});
		
		$x->update;
		
		#die Dumper $x;
	
		return $post;
		
	}
	
	# Implemented from Content::Page::Controller
	sub process_page
	{
		my $self = shift;
		my $type_dbobj = shift;
		my $req  = shift;
		my $r    = shift;
		my $page_obj = shift;
		
		# Change the 'location' of the webmodule so the webmodule code thinks its located at this page path
		# (but %%modpath%% will return /ThemeBryanBlogs for resources such as images)
		my $new_binpath = AppCore::Config->get("DISPATCHER_URL_PREFIX") . $req->page_path; # this should work...
		#print STDERR __PACKAGE__."->process_page: new binpath: '$new_binpath'\n";
		$self->binpath($new_binpath);
		
		## Redispatch thru the ::Module dispatcher which will handle calling main_page()
		#return $self->dispatch($req, $r);
		return $self->events_main($req,$r);
		
# 		# Get a view module from the template based on view code so the template can choose to dispatch a view to a different object if needed
# 		my $view = $self->get_view($view_code,$r);
# 		
# 		# Pass the view code onto the view output function so that it can aggregate different view types into one module
# 		$view->output($page_obj,$r,$view_code);
	};
	
	
	our $EventsListCache = 0;
	sub clear_cached_dbobjects
	{
		#print STDERR __PACKAGE__.": Clearing cached data...\n";
		$EventsListCache = 0;
	}	
	AppCore::DBI->add_cache_clear_hook(__PACKAGE__,'load_basic_events_data');
	
	
	sub events_main
	{
		my $self = shift;
		my ($req,$r) = @_;
		
		#my $section_name = $req->next_path;
		
		my $sub_page = $req->next_path;
		
		my $bin = $self->binpath;
		
		my $can_admin = 1 if ($_ = AppCore::Web::Common->context->user) && $_->check_acl($MGR_ACL);
			
		# Send the CRUD actions to the superclass, which in turn, will call our various hooks, above, for our logic
		if($sub_page eq 'edit' || $sub_page eq 'new' || $sub_page eq  'post')
		{
			$self->board_page($req,$r,$EVENTS_BOARD);
		}
		
# 		elsif($sub_page eq 'delete')
# 		{
# 			AppCore::AuthUtil->require_auth($MGR_ACL);
# 			
# 			my $m = PHC::Events->retrieve($req->{mid});
# 			return $r->error("Invalid MissionID","Invalid MissionID") if !$m;
# 			
# 			$m->deleted(1);
# 			$m->update;
# 			
# 			return $r->redirect($self->binpath);
# 		}
		elsif($sub_page eq 'feed.xml' || $sub_page eq 'rss')
		{
			my $tmpl = $self->rss_feed('events');
			$tmpl->param(feed_title => 'Events');
			$tmpl->param(feed_description => 'Pleasant Hill Church\'s Events Calendar');
			
			$r->content_type('text/xml');
			$r->body($tmpl->output);
			return;
		}
		elsif($sub_page eq 'calendar')
		{
			# TODO
			return $self->calendar_page($req,$r);
		}
		elsif($sub_page eq 'agenda')
		{
			# TODO
			return $self->agenda_view($req,$r);
		}
		elsif(!$sub_page || $sub_page eq 'raw' || $sub_page eq 'basic')
		{
			return $self->basic_view($req,$r);
		}
		elsif($sub_page)
		{
			return $self->board_page($req,$r,$EVENTS_BOARD);
		}
# 		elsif(!$sub_page)
# 		{
# 		
# 			# Default view should be the 'raw' view
# 			
# 			my $tmpl = $self->get_template('events/main.tmpl');
# 			#$tmpl->param(pageid => $section_name);
# 			#$tmpl->param(board_nav => $self->macro_board_nav());
# 			
# 			#$tmpl->param(groupid => $CHANNEL_GROUP->id);
# 			$tmpl->param(can_admin => $can_admin);
# 			
# 			# Wont do anything if loaded, otherwise, loads from DB
# 			$self->load_events_list; 
# 			
# 			$tmpl->param(events_list => $EventsListCache->{page_list});
# 			
# 			my $map_list = $EventsListCache->{map_list};
# 			$tmpl->param(mlist => $map_list);
# 			$tmpl->param(mlist_json => to_json($map_list));
# 			
# 			# TODO
# # 			$r->html_header('link' => 
# # 			{
# # 				rel	=> 'alternate',
# # 				title	=> 'Pleasant Hill Church - Events Updates',
# # 				href 	=> 'http://www.mypleasanthillchurch.org'.$bin.'/events/rss',
# # 				type	=> 'application/rss+xml'
# # 			});
# # 			
# 			#$r->output($tmpl);
# 			my $view = Content::Page::Controller->get_view('sub',$r)->output($tmpl);
# 			
# 			my $body = $r->body;
# 			$body =~ s/<div class='verse-tag-me'>((?:.|\n)+?)<\/div>/Boards::TextFilter::TagVerses::replace_block($1)/segi;
# 			$r->body($body);
# 			
# 			return $r;
# 		}
	}
	
	sub load_basic_events_data
	{
		my $self = shift;
		my $group = shift || 0;
		
		my $key = $group ? 'group:'.$group->id : 'all';
		
		$EventsListCache = {} if !$EventsListCache;
		if(!$EventsListCache->{$key})
		{
			# correct binpath if priming cache outside a HTTP call
			$self->binpath('/connect/events') if $self->binpath =~ /themephc/;
			 
			my $can_admin = 1 if ($_ = AppCore::Common->context->user) && $_->check_acl($MGR_ACL);
			my $sql = "datetime >= NOW() OR is_weekly = 1";
			
			if($group)
			{
				$sql = "($sql) AND groupid=". ($group->id+0);
			}
			#print STDERR "SQL=$sql\n";
			my @events = PHC::Event->retrieve_from_sql($sql);
			
			my @weekly;
			my @dated;
			
			#my $cur_dow = get_dow(EAS::Common::date());
			foreach my $item (@events)
			{
				if($item->event_text =~ /</)
				{
					$item->event_text(AppCore::Web::Common->html2text($item->event_text));
					$item->update;
				}
				
				my $event = $self->merge_item_to_post($item,$can_admin);
				next if !$event || $event->{deleted};
				
				$self->prep_event_hash($event);
				
				if($event->{item}->is_weekly)
				{
					push @weekly, $event;
				}
				else
				{
					push @dated, $event;
				}
			}
			
			@weekly = sort {$a->{item_weekday}  cmp $b->{item_weekday}  } @weekly;
			@dated  = sort {$a->{item_datetime} cmp $b->{item_datetime} } @dated;
			
			# Group by week day
			my $out_weekly = $self->process_weekly_event_list(\@weekly);
			
			$EventsListCache->{$key} = {
				weekly	=> $out_weekly,
				dated	=> \@dated,
			};
		}
		
		return $EventsListCache->{$key};
			 
	}
	
	sub basic_view
	{
		my $self = shift;
		my $req = shift;
		my $r = shift;
		
		my $board = $EVENTS_BOARD;
		
		my $tmpl = $self->get_template($self->config->{list_tmpl} || 'events/list.tmpl');
		#$tmpl->param(pageid => $section_name);
		#$tmpl->param(board_nav => $class->macro_board_nav());
		$tmpl->param('board_'.$_ => $board->get($_)) foreach $board->columns;
		my $can_admin = 1 if ($_ = AppCore::Common->context->user) && $_->check_acl($MGR_ACL);
		$tmpl->param(can_admin=>$can_admin);
		$tmpl->param(events_page => 1);
		
		my $events_data = $self->load_basic_events_data();
		
		#die Dumper $out_weekly, \@dated;
		$tmpl->param(weekly => $events_data->{weekly});
		$tmpl->param(dated  => $events_data->{dated});
		
		#$tmpl->param(weekly_widget => 1);
		
		#return $r->output($tmpl);
		my $view = Content::Page::Controller->get_view('sub',$r)->output($tmpl);
		return $r;
	}
	
	sub merge_item_to_post
	{
		my $self = shift;
		my $item = shift;
		my $can_admin = shift;
		
		my $section_name = 'events';
		my $folder_name = 'events';
		
		my $post = $item->postid;
		if(!$post)
		{
			print STDERR "Debug: invalid postid for item <$item>\n";
			return undef;
		}
		
		#print STDERR "merge_item_to_post: load_post: b: $b, boardid: ".$b->boardid."\n";
		my $board = $post->boardid;
		#print STDERR "merge_item_to_post: load_post: b: $b, boardid: ".$post->boardid.", ref:(".ref($board).")\n";
		
		my $b = {};
		
		my $bin = $self->binpath;
		
		my $short_len = 60;
		
		#EAS::Common::print_stack_trace();
		$b->{$_} = "".$post->get($_) foreach $post->columns;
		$b->{bin} = $bin;
		$b->{pageid} = $section_name;
		$b->{folder_name} = $folder_name;
		$b->{can_admin} = $can_admin;
		$b->{text} =~ s/<(\/)?pre.*?>/<$1p>/g;
		$b->{text} =~ s/<(\/)?span.*?>//g;
		$b->{text} =~ s/<p>&nbsp;<\/p>//gi;
		$b->{text} =~ s/(^<p>|<\/p>$)//g ; #unless index(lc $b->{text},'<p>') > 0;z
		$b->{short_text} = $b->{text};
		$b->{short_text} =~ s/<[^\>]+>//g;
		$b->{short_text} = substr($b->{short_text},0,$short_len) . (length($b->{short_text}) > $short_len ? '...' : '');
		
		$b->{type_event} = 1;  # TODO is this needed?
		
		my $lc = $post->{last_commentid};
		if($lc && $lc->id)
		{
			$b->{'post_'.$_} = "".$lc->get($_) foreach $lc->columns;
			$b->{post_url} = $bin."/$b->{folder_name}#c$lc";
		}
		
		my @keys = keys %$b;
		#$b->{'post_'.$_} = $b->{$_} foreach @keys;
		#$b->{'board_folder_name'} = $BOARD_FOLDER;
		my $post_resultset = $self->SUPER::load_post($post,1); # 1 = dont count view
		$b->{$_} = $post_resultset->{$_} foreach keys %$post_resultset;
			
		$b->{'item_'.$_}  = $item->get($_),"" foreach $item->columns; # TODO which line is needed??
		$b->{'event_'.$_} = $item->get($_)."" foreach $item->columns;
		$b->{item} = $item;
		$b->{post} = $post;
		
		return $b;
	}
	
	sub human_time 
	{
		my $timestamp = shift;
		$timestamp = '12:00:00' if $timestamp eq '00:00:00';
			
		my ($hr,$min,$sec) = split /:/, $timestamp;
		
		my $ap = 'am';
		if($hr >= 12)
		{
			$hr -= 12;
			$ap = 'pm';
			$hr = 12 if !$hr;
		}
		$hr +=0;
		
		return "$hr:$min$ap";
	}
	
	sub prep_event_hash
	{
		my $self = shift;
		my $event = shift;
		my $cur_dow = shift;
		
		my $item = $event->{item};
		if(!$item)
		{
			die "Error loading item for $self, Dump:".Dumper($self, $event).AppCore::Common::get_stack_trace();
		}
		
		my $dow;
		if($item->is_weekly)
		{
			$dow = $item->weekday;
			#$dow = get_dow($event->datetime) if !$dow;
			#print STDERR "Soft Event: dt=".$event->datetime.", dow=$dow\n";
		}
		else
		{
			
			$dow = get_dow($item->datetime);
			#print STDERR "Hard Event: dt=".$item->datetime.", dow=$dow\n";
			
			my $seconds = iso_date_to_seconds($item->datetime) - iso_date_to_seconds(date());
			$event->{time_until} = approx_time_ago(undef, $seconds);
			#die Dumper $event;
		}
		
		my ($datestamp,$timestamp) = split /\s/, $item->datetime;
		
		$event->{time} = human_time($timestamp);
		$event->{end_time} = human_time($item->end_time);
		$event->{same_day} = $cur_dow == $dow;
		$event->{day_name} = $DOW_NAMES[$dow];
		$event->{day_name_short} = $DOW_NAMES_SHORT[$dow];
		$event->{text} = ThemePHC::VerseLookup->tag_verses($event->{text});
		
		my ($year,$mon,$day) = split/-/, $datestamp;
		$event->{normal_datestamp} = (0+$mon)."/".(0+$day)."/".substr($year,-2,2);
		$event->{timestamp} = $timestamp;
		
		$event->{month_name} = $MONTH_NAMES[$mon-1];
		$event->{month_name_short} = $MONTH_NAMES_SHORT[$mon-1];
		
		$event->{year} = $year;
		$event->{day} = $day;
		
		return $dow;
	}
	
	sub get_dow
	{
		my $date = shift;
		my ($x,$y) = split /\s/, $date;
		my ($year,$month,$day) = split/-/, $x;
		my $dt = DateTime->new(year=>$year,month=>$month,day=>$day);
		return $dt->dow;
	}
	
	sub process_weekly_event_list
	{
		my $class = shift;
		
		my $list = shift;
		
		my @weekly = sort {$a->{item_weekday}  cmp $b->{item_weekday}  } @$list;
		
		my @out_weekly;
		my $last_dow;
		my $dow;
		foreach my $item (@weekly)
		{
			if($dow && $dow->{weekday} != $item->{item_weekday})
			{
				$dow->{list} = [ sort { $a->{item_datetime} cmp $b->{item_datetime} } @{$dow->{list}} ];
				push @out_weekly, $dow;
				$dow = undef;
			}
			
			if(!$dow)
			{
				$dow = {list=>[],day_name=>$item->{day_name},weekday=>$item->{item_weekday}};
			}
			
			push @{$dow->{list}}, $item;
			
		}
		
		if($dow)
		{
			$dow->{weekday} = 0 if $dow->{weekday} == 7;
			$dow->{list} = [ sort { $a->{item_datetime} cmp $b->{item_datetime} } @{$dow->{list}} ];
			push @out_weekly, $dow;
			$dow = undef;
			
		}
		
		@out_weekly = sort {$a->{weekday}  cmp $b->{weekday}  } @out_weekly;
		
		return \@out_weekly;
	}
	
	sub _day_data
	{
		my $class = shift;
		my $date = shift;
		my $zoom = shift;
		my $extra = shift || {};
		
		
		my ($x,$y) = split /\s/, $date;
		my ($year,$month,$day) = split/-/, $x;
		my $dt = DateTime->new(year=>$year,month=>$month,day=>$day);
		
		my $data = {};
		my $dow = $dt->dow;
		$data->{weekend} = $dt->dow < 1 || $dt->dow > 5;
		$data->{day} = $dt->day;
		#$data->{bin} = EAS::Common->context->eas_http_bin;
		
		$data->{prev_date} = $dt->subtract(days=>1)->ymd;
		$data->{next_date} = $dt->add(days=>2)->ymd;
		
		#my $url_base = EAS::Common->context->eas_http_bin . '/kitchen';
		#my $eas_root = EAS::Common->context->eas_http_root;
		
		my @day_loop;
		
		my $sql = "datetime like '$year-$month-$day %' OR (is_weekly = 1 AND weekday = $dow)";
		#print STDERR "SQL=$sql\n";
		my @events = PHC::Event->retrieve_from_sql($sql);
		
		#my $cur_dow = get_dow(EAS::Common::date());
		foreach my $item (@events)
		{
		
			#$event->{$_} = $event->get($_) foreach $event->columns;
			#$event->{bin} = $bin;
			my $event = $class->merge_item_to_post($item,$extra->{can_admin});
			next if !$event || $event->{deleted};
			
			$class->prep_event_hash($event);
			
			push @day_loop, $event;
		}
		
		@day_loop = sort {$a->{timestamp} cmp $b->{timestamp} } @day_loop;
		
		my $small_size = 3;
		
		my @day_loop_small;
		push @day_loop_small, $day_loop[$_] for 0.. ($#day_loop < $small_size ? $#day_loop : $small_size);
		
		$data->{day_loop}	= \@day_loop;
		$data->{day_loop_small}	= \@day_loop_small;
		
		$data->{date}		= $date;
		$data->{dow}		= $dt->dow;
		$data->{dow_name}	= $DOW_NAMES[$dt->dow];
		$data->{dow_name_short}	= $DOW_NAMES_SHORT[$dt->dow];
		$data->{dow_letter}	= $DOW_LETTERS[$dt->dow];
		$data->{$_} = $extra->{$_} foreach keys %$extra;
		
		#die '<pre>'.(Dumper $data, \@day_loop).'</pre>';
		return $data;
	}


	sub calendar_page
	{
		#my ($class,$skin,$r,$page,$args,$path) = @_;
		#$r->header('X-Page-Comments-Disabled' => 1);
		my ($self,$req,$r) = @_;
		
		my $tmpl = $self->get_template('events/calendar.tmpl');
		
		my $date = $req->{date} || date();
		my $zoom = $req->{zoom}; # unused
		
		my ($x,$y) = split /\s/, $date;
		my ($year,$month,$day) = split/-/, $x;
		my $dt = DateTime->new(year=>$year,month=>$month,day=>1);
		$tmpl->param(month_name => $MONTH_NAMES[$dt->month-1]);
		
		#die Dumper $dt->month, \@MONTH_NAMES;

		# Move to the beginning of the week for the sake of drawing the calendar
		$dt->subtract( days => $dt->dow ) unless $dt->dow == 7;

		#die Dumper $dt->month, $month;
		my $can_admin = 1 if ($_ = AppCore::Common->context->user) && $_->check_acl($MGR_ACL);
		$tmpl->param(can_admin=>$can_admin);
		#$tmpl->param(pageid=>$page);
		
		# Walk the current month
		my @days;
		my %seen_date = ();
		#my @days;
		#print STDERR "date: $date, month: $month, dtmon: ".$dt->month.", dtday: ".$dt->day."\n";
		# Walk the current month
		while(($dt->month == 12 || $dt->month <= $month) && !defined $seen_date{$dt->day})
		{
			$seen_date{$dt->day} = 1;
			#next if ($dt->ymd cmp $date) < 0;
			
			push @days, $self->_day_data($dt->ymd,$zoom,{cur_month=>$dt->month == $month,can_admin=>$can_admin});
			$dt->add(days=>1);
			#$last_month = $dt->month;
			#last if $dt->day == 1 && $seen1;
			#$seen1 = 1 if $dt->day == 1;
			
		}

		# Now, extend it to the end of the week, again for visual's sake
		unless($dt->dow == 7)
		{
			while($dt->dow <= 7)
			{
				push @days, $self->_day_data($dt->ymd,$zoom,{cur_month=>0,can_admin=>$can_admin});
				$dt->add(days=>1);
				last if $dt->dow == 7;
			}
		}

		# Split the list of days into distinct weeks
		my $bin = $self->binpath; #PHC::Web::Context->http_bin;
		my @weeks;
		my $cur_week;
		for my $day (0..$#days)
		{
			if($day % 7 == 0)
			{
				push @weeks, {days=>$cur_week,bin=>$bin} if $cur_week;
				$cur_week = [];
			}
			push @$cur_week, $days[$day]; #->{date}; 
		}
		push @weeks, {days=>$cur_week} if $cur_week;

		# Debug
		#die '<pre>'.(Dumper $zoom, \@weeks).'</pre>';
		$tmpl->param(days  => \@days);
		$tmpl->param(weeks => \@weeks);

		# Now, build the calendar navigation bar at the top
		my $p_year = $year - 1;
		my $n_year = $year + 1;

		$tmpl->param(month => $MONTH_NAMES[$month-1]);
		
		my $datesel_base = $self->binpath .'/calendar?date=';
		$tmpl->param(last_year_url => $datesel_base . join('-', $p_year, rpad($month), rpad($day)));
		$tmpl->param(next_year_url => $datesel_base . join('-', $n_year, rpad($month), rpad($day)));
		$tmpl->param(last_year => $p_year);
		$tmpl->param(next_year => $n_year);
		$tmpl->param(this_year => $year);
		

		my @mini_months = qw(Jan Feb Mar Apr May Jun Jul Aug Sept Oct Nov Dec);
		my @month_loop;

		# Again,.a nice little bit of historical code ripped from ConfRooms.pl 
		for my $x (0..$#mini_months)
		{
			my %row;
			$row{mini_month} = $mini_months[$x];
			$row{month} = $MONTH_NAMES[$x];
			$row{is_cur_month} = ($x+1) == $month;
			$row{month_url} = $datesel_base . join('-',$year,rpad($x+1),rpad($day));
			push @month_loop,\%row;
		}
		$tmpl->param(months=>\@month_loop);
		
		
		
		#$r->output($tmpl);
		my $view = Content::Page::Controller->get_view('sub',$r);
		#$view->breadcrumb_list->push('',$self->module_url('/claim?familyid='.$fam),0);
		$view->breadcrumb_list->push('Calendar View',$self->module_url('/calendar'),0);
		$view->output($tmpl);
		return $r;
		
		
	}

# 	
# 	
# 	
# 	sub load_events_list
# 	{
# 		my $self = shift;
# 		if(!$EventsListCache)
# 		{
# 			my @events = PHC::Events->search(deleted=>0);
# 			
# 			my %country_groups;
# 			
# 			my $bin = $self->binpath;
# 			
# 			# Force US to the top and International to the bottom of the list
# 			my %sort_keys = ('united states' => '0', 'international' => 'zzzzzzzzzzzzz');
# 			foreach my $x (@events)
# 			{
# 				my $c = lc $x->country;
# 				
# 				$country_groups{$c} ||= { country => $x->country, list => [] };
# 				
# 				$self->prep_mission_item($x);
# 				
# 				#die Dumper $x;
# 				
# 				push @{$country_groups{$c}->{list}}, $x;
# 				
# 				if(!defined $sort_keys{$c})
# 				{
# 					$sort_keys{$c} = $c;
# 				}
# 			}
# 			
# 			my @country_sort = sort { $sort_keys{$a} cmp $sort_keys{$b} } keys %country_groups;
# 			my @list = map { $country_groups{$_} } @country_sort;
# 			
# 			my @map_list;
# 			foreach my $m (@events)
# 			{
# 				my $ref = {};
# 				
# 				$ref->{$_} = $m->get($_) foreach qw/missionid city country mission_name family_name photo_url lat lng deleted/;
# 				
# 				$ref->{binpath} = $bin;
# 				$ref->{'board_'.$_} = $m->boardid->get($_) foreach qw/folder_name section_name/;
# 				$ref->{list_title} = $m->family_name ? $m->family_name : $m->mission_name;
# 				
# 				push @map_list, $ref;
# 			}
# 			
# 			$EventsListCache = 
# 			{
# 				page_list => \@list,
# 				map_list  => \@map_list,
# 			};
# 		}
# 		
# 		return $EventsListCache->{page_list};
# 	}
# 	
# 	sub create_folder_title
# 	{
# 		my $class = shift;
# 		my $m = shift;
# 		
# 		my @args;
# 		push @args, $m->country;
# 		push @args, $m->mission_name;
# 		push @args, $m->family_name if $m->family_name;
# 		push @args, $m->city if $m->city;
# 		
# 		return join ' - ', @args;
# 	}
# 	
# 	sub create_country_list_title
# 	{
# 		my $class = shift;
# 		my $m = shift;
# 
# 		my @args;
# 		push @args, $m->mission_name;
# 		push @args, $m->family_name if $m->family_name;
# 		push @args, $m->city if $m->city;
# 
# 		return join ' - ', @args;
# 	}
# 	
# 	sub create_folder_name
# 	{
# 		my $class = shift;
# 		my $m = shift;
# 		
# 		return $m->family_name ? $m->family_name : $m->mission_name;
# 		
# 	}
# 	
# 	sub create_tagline 
# 	{
# 		my $class = shift;
# 		my $mission = shift;
# 		my $txt = AppCore::Web::Common::html2text($mission->description);
# 		return substr($txt,0,255) . (length($txt) > 255 ? '...':'');
# 	}
# 	
# 	sub create_description
# 	{
# 		my $class = shift;
# 		my $m = shift;
# 		return $m->description;
# 	}
# 	
# 	sub prep_mission_item
# 	{
# 		my $class = shift;
# 		my $m = shift;
# 		
# 		my $board = $class->check_webboard($m);
# 		
# 		$m->{binpath} = $class->binpath;
# 		$m->{$_} = $m->get($_) foreach $m->columns;
# 		$m->{'board_'.$_} = $board->get($_) foreach $board->columns;
# 		$m->{list_title} = $class->create_country_list_title($m);
# 	}
# 	
# 	sub check_webboard
# 	{
# 		my $class = shift;
# 		my $m = shift;
# 		my $board = $m->boardid;
# 		
# 		if(!$board || !$board->id)
# 		{
# 			$board = Boards::Board->create({
# 				groupid		=> $CHANNEL_GROUP,
# 				section_name	=> $BOARD_FOLDER,
# 				folder_name	=> $class->to_folder_name($class->create_folder_name($m)),
# 				title		=> $class->create_folder_title($m),
# 				tagline		=> $class->create_tagline($m),
# 				description	=> $class->create_description($m),
# 			});
# 
# 			$m->boardid($board);
# 			$m->update;
# 
# 		}	
# 
# 		else
# 		{
# 			my $title = $class->create_folder_title($m);
# 			my $folder = $class->to_folder_name($class->create_folder_name($m));
# 
# 			$board->title($title)        if $board->title  ne $title;
# 			$board->folder_name($folder) if $board->folder_name ne $folder;
# 			$board->update if $board->is_changed;
# 		}
# 		
# 		return $board;
# 	}
	
	
}


1;
