class EloController < ApplicationController
  around_filter :error_handling
  before_filter :verify_slack_signature

  VICTORY_TERMS = ['beat', 'defeated', 'conquered', 'won against', 'got the better of', 'vanquished', 'trounced',
                   'routed', 'overpowered', 'overcame', 'overwhelmed', 'overthrew', 'subdued', 'quashed', 'crushed',
                   'thrashed', 'whipped', 'wiped the floor with', 'clobbered', 'owned', 'pwned', 'wrecked']
  TIED_TERMS = ['tied', 'drawed']

  SLACK_ID_REGEX = '<([^\|>]*)[^>]*>'

  def elo
    render json: {message: "missing parameter team_id"}, status: :bad_request if params[:team_id].blank?
    render json: {message: "missing parameter user_id"}, status: :bad_request if params[:user_id].blank?
    return help if params[:text].empty? || params[:text] == "help"
    command, _, other = params[:text].partition(" ")
    case command
    when "rating"
      rating
    when "leaderboard"
      leaderboard(other)
    when "register"
      register(other)
    when "games"
      games
    else
      game
    end
    render json: @response, status: :ok
  end

  private

  def verify_slack_signature
    return if ENV['SKIP_SLACK_SIGNING'] # for easier dev debugging
    version_number = 'v0' # always v0 for now
    timestamp = request.headers['X-Slack-Request-Timestamp']
    raw_body = request.body.read
    sig_basestring = [version_number, timestamp, raw_body].join(':')

    signing_secret = ENV['SLACK_SIGNING_SECRET'].to_s
    digest = OpenSSL::Digest::SHA256.new
    hex_hash = OpenSSL::HMAC.hexdigest(digest, signing_secret, sig_basestring)
    computed_signature = [version_number, hex_hash].join('=')
    slack_signature = request.headers['X-Slack-Signature']

    render nothing: true, status: :unauthorized if computed_signature != slack_signature
  end

  def error_handling
    ActiveRecord::Base.transaction do
      yield
    end
  rescue => e
    Rails.logger.error "#{e.message}\n#{e.backtrace.first(5).join("\n")}"
    reply "Uh oh! Something went wrong. Please contact Alex. :dusty_stick:", error: true
    render json: @response, status: :ok
  end

  def help
    attachments = [
        {
            text:
                "`/elo [@winner] defeated [@loser] at [game]` - Logs a game between these players and updates their ratings accordingly.\n" <<
                    "`/elo [@player1] tied [@player2] at [game]` - Logs a tie game between these players and updates their ratings accordingly.\n" <<
                    "`/elo leaderboard [game]` - Displays the leaderboard for the specified game.\n" <<
                    "`/elo rating` - Displays your Elo rating for all types of games you've played.\n" <<
                    "`/elo games` - Lists all registered games for this team. (a.k.a. Valid inputs for [game] in other commands).\n" <<
                    "`/elo register [game]` - Registers this as a type of game that this team plays.\n" <<
                    "`/elo help` - Shows this message."
        }
    ]
    reply ":wave: Need some help with `/elo`? Here are some useful commands:", attachments: attachments
  end

  def leaderboard(type)
    return help unless type.present?

    game_type = find_game_type(type)
    return unless game_type

    singles = Player.where(team_id: current_team, game_type_id: game_type.id, team_size: 1).order(rating: :desc).take(10)
    doubles = Player.where(team_id: current_team, game_type_id: game_type.id, team_size: 2).order(rating: :desc).take(10)
    attachments = []

    reply "No one has played any ELO rated games of #{type} yet." and return if singles.empty? && doubles.empty?

    text = "Here is the current leaderboard for #{type}:"
    if singles.present?
      attachments << {
          text: singles.each_with_index.map { |player, index| "#{index + 1}. #{player.team_tag} (#{player.rating})" }.join("\n"),
          footer: ":mat_icon_person: | Accurate as of #{Time.now.strftime('%B %d, %Y %l:%M%P %Z')}"
      }
    end
    if doubles.present?
      attachments << {
          text: doubles.each_with_index.map { |player, index| "#{index + 1}. #{player.team_tag} (#{player.rating})" }.join("\n"),
          footer: ":mat_icon_people: | Accurate as of #{Time.now.strftime('%B %d, %Y %l:%M%P %Z')}"
      }
    end
    reply text, attachments: attachments
  end

  def rating
    players = Player.where(team_id: current_team).where("user_id like ?", "%#{current_user}%").includes(:game_type).to_a
    text = if players.empty?
             "You haven't played any ELO rated games yet."
           else
             players.map { |player| "Your rating in #{player.game_type.game_type} #{player.doubles? ? ":mat_icon_people:" : ":mat_icon_person:"} is #{player.rating}." }.join("\n")
           end
    reply text
  end

  def register(type)
    return help unless type.present?

    game_type = GameType.where(team_id: current_team, game_type: type).take
    reply "That game has already been registered." and return if game_type.present?

    game_type = GameType.create!(team_id: current_team, game_type: type)
    reply "Successfully registered #{game_type.game_type} for this team!"
  end

  def games
    game_types = GameType.where(team_id: current_team).to_a
    text = if game_types.empty?
             "No types of games have been registered for this team yet. Try `/elo register [game]`."
           else
             "Here are all the registered types of games for this team:\n#{game_types.map { |game_type| "• #{game_type.game_type}" }.join("\n")}"
           end
    reply text
  end

  def game
    _, p1, p2, verb, p3, p4, type = params[:text].match(/^#{SLACK_ID_REGEX}(?: +and +#{SLACK_ID_REGEX})? +([a-z ]*) +#{SLACK_ID_REGEX}(?: +and +#{SLACK_ID_REGEX})? +at +(.*)$/).to_a
    return help if p1.blank? || p3.blank? || type.blank?

    reply "2 on 1 isn't very fair :dusty_stick:" and return if [p2, p4].compact.count == 1
    reply "A third-party witness must enter the game for it to count." and return if [p1, p2, p3, p4].include? current_user
    reply ":areyoukiddingme:" and return if ([p1, p2, p3, p4].compact & %w(@USLACKBOT !channel !here)).present?
    team_size = p2.present? && p4.present? ? 2 : 1
    reply "Am I seeing double or did you enter the same person multiple times? :twinsparrot:" and return if [p1, p2, p3, p4].compact.uniq.count != team_size * 2

    game_type = find_game_type(type)
    return unless game_type

    team1 = Player.where(team_id: current_team, user_id: [p1, p2].compact.sort.join('-'), game_type_id: game_type.id, team_size: team_size).first_or_initialize
    team2 = Player.where(team_id: current_team, user_id: [p3, p4].compact.sort.join('-'), game_type_id: game_type.id, team_size: team_size).first_or_initialize

    case verb.strip
    when *VICTORY_TERMS
      team1.won_against team2, current_user
      reply "Congratulations to #{team1.team_tag} (#{team1.rating_change}) :#{win_emoji}: on defeating #{team2.team_tag} (#{team2.rating_change}) :#{lose_emoji(team2.team_tag)}: at #{type}!", in_channel: true
    when *TIED_TERMS
      team1.tied_with team2, current_user
      reply "#{team1.team_tag} (#{team1.rating_change}) :#{win_emoji}: tied #{team2.team_tag} (#{team2.rating_change}) :#{win_emoji}: at #{type}.", in_channel: true
    else
      return help
    end
  end

  def find_game_type(type)
    game_type = GameType.where(team_id: current_team, game_type: type).take
    return game_type unless game_type.nil?
    attachments = [
        {
            text:
                "`/elo games` - Lists all registered games for this team. (a.k.a. Valid inputs for [game] in other commands).\n" <<
                    "`/elo register [game]` - Registers this as a type of game that this team plays."
        }
    ]
    reply "The game of #{type} has not be registered for this team yet. Try using one of the following commands to find or register the game you're looking for.", attachments: attachments
    return nil
  end

  def reply(text, in_channel: false, attachments: [], error: false)
    raise "double reply. original messages:\n#{@response[:text]}\n#{text}" if @response.present? && !error
    @response = {
        response_type: in_channel ? "in_channel" : "ephemeral",
        text: text,
        attachments: attachments
    }
  end

  def win_emoji()
    %w(aaw_yeah awesome awesomesauce awwyeah bananadance carlton cheers clapping congrats dabward dancing_pickle dank datboi deadpool drake excellent fancy fastparrot feelssogood fiestaparrot foleydance gandalf gusta happytony happy_cloud happy_tim heh-heh-heh-hao-owrrrr-rah-heh-heh-heh-heh-huh-huh-haow-hah-haough johncena mat_icon_whatshot nailedit notinmyhouse nyan obama_not_bad parrot party-corgi partywizard party_dino party_frog party_mim_cat party_trash_dove pewpew quag rekt slav_squat spiderman success sunglasses-on-a-baby thanks travis_passed very_nice woohoo yeah yeet yes).sample
  end

  def lose_emoji(team)
    return 'shame' if team.include?('@UBK70UVP1')
    %w(angrytony angry_tim backs-away bruh collins crying disappear disappointed_jacob doh doodie drypenguin dumpster_fire facepalm feelsbad flood garbage grumpycat haha leftshark mooning nooooooo numb okay okthen oof patrickboo puddlearm puke raised_eyebrow sadparrot sadpepe sad_mac sad_rowser santa-derp shame somebodykillme surprised_pikachu swear thisstraycatlookslikegrandma travis_failed triggered unimpressed wellthen why wowen wtf yuno).sample
  end

  def current_team
    params[:team_id]
  end

  def current_user
    "@#{params[:user_id]}"
  end
end