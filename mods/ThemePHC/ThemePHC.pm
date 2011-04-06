use strict;

package ThemePHC;
{
	use Content::Page;
	use base 'Content::Page::ThemeEngine';
	use Scalar::Util 'blessed';

	
	# The output() routine is the core of the Theme - it's where the theme applies the
	# data from the Content::Page object and any optional $parameters given
	# to the HTML template and sends the template out to the browser.
	# The template chosen is (should be) based on the $view_code requested by the controller.
	sub output
	{
		my $self       = shift;
		my $page_obj   = shift || undef;
		my $r          = shift || $self->{response};
		my $view_code  = shift || $self->{view_code};
		my $parameters = shift || {};
		
		my $tmpl = undef;
		#print STDERR __PACKAGE__."::output: view_code: '$view_code'\n";
		if($view_code eq 'home')
		{
			$tmpl = $self->load_template('frontpage.tmpl');
		}
		# Don't test for 'sub' now because we just want all unsupported view codees to fall thru to subpage
		#elsif($view_code eq 'sub')
		else
		{
			$tmpl = $self->load_template('subpage.tmpl');
		}
		
		## Add other supported view codes
			
		if(!$self->apply_page_obj($tmpl,$page_obj))
		{
			my $blob = (blessed $page_obj && $page_obj->isa('HTML::Template')) ? $page_obj->output : $page_obj;
			my @titles = $blob=~/<title>(.*?)<\/title>/g;
			#$title = $1 if !$title;
			@titles = grep { !/\$/ } @titles;
			$tmpl->param(page_title => shift @titles);
			$tmpl->param(page_content => $blob);
		}
			
		#$r->output($page_obj->content);
		$r->output($tmpl->output);
	};
	
};
1;