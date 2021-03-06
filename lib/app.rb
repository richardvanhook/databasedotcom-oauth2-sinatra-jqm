require "sinatra/base"
require "rack/ssl" unless ENV['RACK_ENV'] == "development" # only utilized when deployed to heroku
require "base64"
require "addressable/uri"
require "databasedotcom"
require "databasedotcom-oauth2"
require "haml"

class App < Sinatra::Base

  ENV_VARS = %w(TOKEN_ENCRYPTION_KEY CLIENT_ID CLIENT_SECRET CLIENT_SANDBOX_ID CLIENT_SANDBOX_SECRET)
  ENV_VARS.keep_if{|var| ENV[var].nil?}
  fail "Following Environment Variables must not be null: #{ENV_VARS.join(',')}" if !ENV_VARS.empty?

  configure do
    enable :logging
    set :app_file            , __FILE__
    set :root                , File.expand_path("../..",__FILE__)
    set :port                , ENV['PORT']
    set :raise_errors        , Proc.new { false }
    set :show_exceptions     , true
    set :token_encryption_key, Base64.strict_decode64(ENV['TOKEN_ENCRYPTION_KEY'])
    set :endpoints           , nil
    set :default_endpoint    , :"login.salesforce.com"
    set :displays            , %w(page popup touch mobile)
    set :default_display     , "page"
    set :scopes              , %w(api chatter_api full id refresh_token visualforce web)
    set :default_scopes      , %w(api chatter_api id refresh_token)
    set :prompts             , %w(login consent)
  end

  settings.endpoints = {
    settings.default_endpoint => {
      :key      => ENV['CLIENT_ID'], 
      :secret   => ENV['CLIENT_SECRET']}, 
    "test.salesforce.com" => {
      :key      => ENV['CLIENT_SANDBOX_ID'],
      :secret   => ENV['CLIENT_SANDBOX_SECRET']}
  }
  settings.endpoints.default = endpoints[settings.default_endpoint]

  # Rack Middleware
  use Rack::SSL unless ENV['RACK_ENV'] == "development" # only utilized when deployed to heroku
  use Rack::Session::Cookie, :expire_after => 60*60*7    # holds oauth2 token in encrypted, serialized form
  use Databasedotcom::OAuth2::WebServerFlow, 
    :endpoints            => settings.endpoints, 
    :token_encryption_key => settings.token_encryption_key,
    :path_prefix          => "/auth/salesforce",
    :on_failure           => nil,
    :debugging            => true,
    :prompt_override      => true,
    :scope_override       => true,
    :display_override     => true,
    :immediate_override   => true

  # mixes in client, me, authenticated?, etc.
  include Databasedotcom::OAuth2::Helpers

  # Routes
  get '/authenticate' do
	  if unauthenticated?
      haml :terms, :layout => :login, :locals => { :url => '/auth/salesforce', :state => params[:state] }
    else
      redirect to(sanitize_state(params[:state])) 
    end
  end

  get '/unauthenticate' do
    client.logout if authenticated?
    redirect to("/")
  end

  get '/error' do
    haml :error, :locals => {:title => params[:title], :message => params[:message]}
  end
  
  get '/terms' do
    haml :terms
  end
  
  get '/describe/:obj' do
    authenticate!
    begin
      haml :describe, :locals => {:typemap => client.materialize(params[:obj]).type_map.sort}
    rescue Exception => e
      return error(e)
    end
  end
  
  get '/*' do
    authenticate!
    begin
      haml :list, :locals => {:sobjects => client.list_sobjects}
    rescue Exception => e
      return error(e)
    end
    
  end

  # Helpers
  helpers do
  	def authenticate!
  	  if unauthenticated?
        uri = Addressable::URI.new
        uri.query_values = {:state => request.fullpath}
    	  redirect to("/authenticate?#{uri.query}") 
  	  end
  	end

    def error(exception)
      _log_exception(exception)
      new_path = Addressable::URI.parse("/error")
      new_path.query_values={:title => "An error occurred", :message => exception.message}
      [302, {'Location' => new_path.to_s, 'Content-Type'=> 'text/html'}, []]
    end
    
    def sanitize_state(state = nil)
      state = "/" if state.nil? || state.strip.empty?
      state
    end
    
    def htmlize_hash(title, hash)
      hashes = nil
      strings = nil
      hash.each_pair do |key, value|
        case value
        when Hash
          hashes ||= ""
          hashes << htmlize_hash(key,value)
        else
          strings ||= "<table>"
          strings << "<tr><td>#{key}</th><td>#{value}</td></tr>"
        end
      end
      output = "<div data-role='collapsible' data-content-theme='c'><h3>#{title}</h3>"
      output << strings unless strings.nil?
      output << "</table>" unless strings.nil?
      output << hashes unless hashes.nil?
      output << "</div>"
      output
    end

    def _log_exception(exception)
      STDERR.puts "\n\n#{exception.class} (#{exception.message}):\n    " +
        exception.backtrace.join("\n    ") +
        "\n\n"
    end
    
  end

end