require 'discordrb'

module Cosgrove
  require 'cosgrove/snark_commands'
  
  cattr_accessor :latest_steemit_link
  
  @@latest_steemit_link = {}
  
  class Bot < Discordrb::Commands::CommandBot
    include Support
    include SnarkCommands
    
    def initialize(options = {})
      options[:token] ||= cosgrove_token
      options[:client_id] ||= cosgrove_client_id
      super(options)
      
      @on_success_upvote_job = options[:on_success_upvote_job]
      @on_success_register_job = options[:on_success_register_job]
      
      self.bucket :voting, limit: 10, time_span: 60*60*24, delay: 10

      add_all_commands
      add_all_messages
      SnarkCommands::add_all_snark_commands(self)
    end
    
    def add_all_messages
      # A user typed a link to steemit.com
      self.message(content: /http[s]*:\/\/steemit\.com\/.*/, ignore_bots: false) do |event|
        link = event.content.split(' ').first
        Cosgrove::latest_steemit_link[event.channel.name] = link
        append_link_details(event, link)
      end
    end
    
    def add_all_commands
      self.command :help do |_event, *args|
        help = []
        help << "`..slap [target]` - does a slap on the `target`"
        help << "`..verify <account> [chain]` - check `account` association with Discord users (`chain` default `steem`)"
        help << "`..register <account> [chain]` - associate `account` with your Discord user (`chain` default `steem`)"
        help << "`..upvote [url]` - upvote from #{steem_account}; empty or `^` to upvote last steemit link; also comments and resteems. any further text is placed in the comment."
        help << "`..power <account>` - Check voting power of account."
        help.join("\n")
      end
      
      self.command :version do |_|
        "cosgrove: #{Cosgrove::VERSION} :: https://github.com/steem-third-party/cosgrove"
      end

      self.command :power do |event, account_name = steem_account|
        account = find_account(account_name)
        event.respond "Voting Power for #{account_name}: #{account.voting_power / 100.0}%"
      end

      self.command :upvote_queue do |event|
	      response = "Queue: \n"
	      Cosgrove::UpvoteJob::upvote_queue.each_with_index do |x, i|
		      response += "#{i+1}. #{x[:vote][:author]}/#{x[:vote][:permlink]}\n"
	      end
	      event.respond(response)
      end
      
      self.command :verify do |event, key, chain = :steem|
        return if event.channel.pm? && !cosgrove_allow_pm_commands
        cb_account = nil
        
        if key.nil?
          event.respond "Account to verify missing."
          return
        end
        
        account = find_account(key, event)
        
        if !!account && account.respond_to?(:name)
          cb_account = Cosgrove::Account.new(account.name, chain)
        else
          discord_id = key.split('@').last.split('>').first.to_i
          cb_account = Cosgrove::Account.find_by_discord_id(discord_id, chain)
        end
        
        account = cb_account.chain_account if account.nil? && !!cb_account
        
        if !!account && !!cb_account && cb_account.discord_ids.any?
          if cb_account.hidden?
            "#{chain.to_s.upcase} account `#{account.name}` has been registered."
          else
            discord_ids = cb_account.discord_ids.map { |id| "<@#{id}>" }
            
            "#{chain.to_s.upcase} account `#{account.name}` has been registered with #{discord_ids.to_sentence}."
          end
        elsif !!account
          "#{chain.to_s.upcase} account `#{account.name}` has not been registered with any Discord account.  To register:\n`..register #{account.name}`"
        elsif discord_id.to_i > 0
          "<@#{discord_id}> has not been associated with a #{chain.to_s.upcase} account.  To register:\n`..register <account>`"
        else
          "No association found.  To register:\n`..register <account>`"
        end
      end
      
      self.command :register do |event, account_name, chain = :steem|
        return if event.channel.pm? && !cosgrove_allow_pm_commands
        
        discord_id = event.author.id
        
        if discord_id.to_i == 0
          event.respond 'Problem with discord id.'
          return
        end
        
        account = find_account(account_name, event, chain)
        
        if account.nil?
          event.respond 'Try again later.'
          return
        end
        
        cb_account = Cosgrove::Account.new(account.name, chain)
        
        if cb_account.discord_ids.include? discord_id
          event.respond "Already registered `#{account.name}` on `#{chain.upcase}` with <@#{discord_id}>"
          return
        end
        
        memo_key = cb_account.memo_key(discord_id)
        op = find_transfer(chain: chain, account: steem_account, from: account.name, to: steem_account, memo_key: memo_key)
          
        if !!op
          cb_account.add_discord_id(discord_id)
          
          if !!@on_success_register_job
            begin
              @on_success_register_job.call(event, cb_account)
            rescue => e
              ap e
              ap e.backtrace
            end
          end
          
          "Ok.  #{chain.to_s.upcase} account #{account.name} has been registered with <@#{discord_id}>."
        else
          "To register `#{account.name}` with <@#{discord_id}>, send `0.001 #{core_asset}` or `0.001 #{debt_asset}` to `#{steem_account}` with memo: `#{memo_key}`\n\nThen type `..register #{account.name}` again."
        end
      end
     
      def doUpvote(event, language, slug, *args)
        return if event.channel.pm? && !cosgrove_allow_pm_commands
       
        discord_id = event.author.id
        cb_account = Cosgrove::Account.find_by_discord_id(discord_id)
        account_name = nil
        account_name = cb_account.chain_account.name if !!cb_account && !!cb_account.chain_account

        slug = Cosgrove::latest_steemit_link[event.channel.name] if slug.nil? || slug.empty? || slug == '^'
        custom_message = args.join(' ')
        options = {
          on_success: lambda { |event, slug|
             @on_success_upvote_job.call(event, slug, custom_message, language)
	     open('curated.csv', 'a') { |f|
	       f.puts "CURATE,#{Time.now.getutc},#{discord_id},#{account_name},#{slug}"
	     }
          }
        }

        Cosgrove::UpvoteJob.new(options).perform(event, slug)
      end 

      self.command(:upvote, bucket: :voting, rate_limit_message: 'Sorry, you are in cool-down. Please wait %time% more seconds.') do |event, slug, *args|
        doUpvote(event, 'english', slug, *args)
      end

      self.command(:vota, bucket: :voting, rate_limit_message: 'Sorry, you are in cool-down. Please wait %time% more seconds.') do |event, slug, *args|
        doUpvote(event, 'spanish', slug, *args)
      end

    end
  end
end
