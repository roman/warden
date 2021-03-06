module Warden
  class UserNotSet < RuntimeError; end

  class Proxy
    # :api: private
    attr_accessor :winning_strategy
    
    # An accessor to the rack env hash
    # :api: public
    attr_reader :env
    
    extend ::Forwardable
    include ::Warden::Mixins::Common
    alias_method :_session, :session
          
    # :api: private
    def_delegators :winning_strategy, :headers, :_status, :custom_response

    def initialize(env, config = {}) # :nodoc:
      @env = env
      @config = config
      @strategies = @config.fetch(:default_strategies, [])
      @users = {}
      errors # setup the error object in the session
    end

    # Check to see if there is an authenticated user for the given scope.
    # When scope is not specified, :default is assumed.
    # This will not try to reconstitute the user from the session and will simply check for the 
    # existance of a session key
    # 
    # Parameters: 
    #   scope - the scope to check for authentication.  Defaults to :default
    #
    # Example: 
    #   env['warden'].authenticated?(:admin)
    # :api: public
    def authenticated?(scope = :default)
      !_session["warden.user.#{scope}.key"].nil?
    end # authenticated?
    
    # Run the authentiation strategies for the given strategies.  
    # If there is already a user logged in for a given scope, the strategies are not run
    # This does not halt the flow of control and is a passive attempt to authenticate only
    # When scope is not specified, :default is assumed.
    # 
    # Parameters: 
    #   args - a list of symbols (labels) that name the strategies to attempt
    #   opts - an options hash that contains the :scope of the user to check
    #
    # Example:
    #   env['auth'].authenticate(:password, :basic, :scope => :sudo)
    # :api: public
    def authenticate(*args)
      scope = scope_from_args(args)
      _perform_authentication(*args)
      user(scope)
    end
    
    # The same as +authenticate+ except on failure it will throw an :warden symbol causing the request to be halted
    # and rendered through the +failure_app+
    # 
    # Example 
    #   env['warden'].authenticate!(:password, :scope => :publisher) # throws if it cannot authenticate
    #
    # :api: public
    def authenticate!(*args)
      opts = opts_from_args(args)
      scope = scope_from_args(args)
      _perform_authentication(*args)
      throw(:warden, opts.merge(:action => :unauthenticated)) if !user(scope)
      user(scope)
    end
    
    # Manually set the user into the session and auth proxy
    # 
    # Parameters:
    #   user - An object that has been setup to serialize into and out of the session.
    #   opts - An options hash.  Use the :scope option to set the scope of the user
    # :api: public
    def set_user(user, opts = {})
      scope = (opts[:scope] ||= :default)
      Warden::Manager._store_user(user, _session, scope) # Get the user into the session
      
      # Run the after hooks for setting the user
      Warden::Manager._after_set_user.each{|hook| hook.call(user, self, opts)}
      
      @users[scope] = user # Store the user in the proxy user object
    end
    
    # Provides acccess to the user object in a given scope for a request.
    # will be nil if not logged in
    # 
    # Example:
    #   # without scope (default user)
    #   env['warden'].user
    #
    #   # with scope 
    #   env['warden'].user(:admin)
    #
    # :api: public
    def user(scope = :default)
      @users[scope] ||= lookup_user_from_session(scope)
    end
    
    # Provides a scoped session data for authenticated users.
    # Warden manages clearing out this data when a user logs out
    #
    # Example
    #  # default scope
    #  env['warden'].data[:foo] = "bar"
    #
    #  # :sudo scope
    #  env['warden'].data(:sudo)[:foo] = "bar"
    #
    # :api: public
    def session(scope = :default)
      raise NotAuthenticated, "#{scope.inspect} user is not logged in" unless authenticated?(scope)
      _session["warden.user.#{scope}.session"] ||= {}
    end
    
    # Provides logout functionality. 
    # The logout also manages any authenticated data storage and clears it when a user logs out.
    #
    # Parameters:
    #   scopes - a list of scopes to logout
    #
    # Example:
    #  # Logout everyone and clear the session
    #  env['warden'].logout
    #
    #  # Logout the default user but leave the rest of the session alone
    #  env['warden'].logout(:default)
    #
    #  # Logout the :publisher and :admin user
    #  env['warden'].logout(:publisher, :admin)
    # 
    # :api: public
    def logout(*scopes)
      if scopes.empty?
        _session.clear
        @users.clear
      else
        scopes.each do |s|
          _session["warden.user.#{s}.key"] = nil
          _session["warden.user.#{s}.session"] = nil
          @users.delete(s)
        end
      end
    end
    
    # proxy methods through to the winning strategy
    # :api: private
    def result # :nodoc: 
       winning_strategy.nil? ? nil : winning_strategy.result
    end
    
    # Proxy through to the authentication strategy to find out the message that was generated.
    # :api: public
    def message
      winning_strategy.nil? ? "" : winning_strategy.message
    end
    
    # Provides a way to return a 401 without warden defering to the failure app
    # The result is a direct passthrough of your own response
    # :api: public
    def custom_failure!
      @custom_failure = true
    end
    
    # Check to see if the custom failur flag has been set
    # :api: public
    def custom_failure?
      !!@custom_failure
    end
    
    private 
    # :api: private
    def _perform_authentication(*args)
      scope = scope_from_args(args)
      opts = opts_from_args(args)
      
      # Look for an existing user in the session for this scope
      if the_user = user(scope)
        return the_user
      end
      
      # If there was no user in the session.  See if we can get one from the request
      strategies = args.empty? ? @strategies : args
      raise "No Strategies Found" if strategies.empty? || !(strategies - Warden::Strategies._strategies.keys).empty?
      strategies.each do |s|
        strategy = Warden::Strategies[s].new(@env, @conf)
        self.winning_strategy = strategy
        next unless strategy.valid?
        strategy._run!
        break if strategy.halted?
      end
      
      
      if winning_strategy && winning_strategy.user
        set_user(winning_strategy.user, opts)
      
        # Run the after_authentication hooks
        Warden::Manager._after_authentication.each{|hook| hook.call(winning_strategy.user, self, opts)}
      end
      
      winning_strategy
    end
    
    # :api: private
    def scope_from_args(args)
      Hash === args.last ? args.last.fetch(:scope, :default) : :default
    end
    
    # :api: private
    def opts_from_args(args)
      Hash === args.last ? args.pop : {}
    end

    # :api: private
    def lookup_user_from_session(scope)
      set_user(Warden::Manager._fetch_user(_session, scope), :scope => scope)
    end
  end # Proxy
end # Warden