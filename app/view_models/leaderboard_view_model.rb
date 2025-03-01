class LeaderboardViewModel < PlayerViewModel
  class << self
    def leaderboard(team_id:, game_type_id:)
      singles = list(team_id: team_id, game_type_id: game_type_id, team_size: 1).items
      doubles = list(team_id: team_id, game_type_id: game_type_id, team_size: 2).items

      data = []
      data << attachment(singles.join("\n"), doubles: false) if singles.present?
      data << attachment(doubles.join("\n"), doubles: true) if doubles.present?
      new(data)
    end

    def surrounding_ranks(player)
      players = Player.find_by_sql([<<-SQL, team_id: player.team_id, user_id: player.user_id, game_type_id: player.game_type_id, team_size: player.team_size])
        WITH ranked_players AS (SELECT players.*, DENSE_RANK() OVER (ORDER BY rating DESC) AS rank
                                FROM players
                                WHERE players.team_id = :team_id
                                  AND players.game_type_id = :game_type_id
                                  AND players.team_size = :team_size)
        SELECT *
        FROM ranked_players
        WHERE ranked_players.rank BETWEEN (SELECT rank - 1 FROM ranked_players WHERE user_id = :user_id)
                  AND (SELECT rank + 1 FROM ranked_players WHERE user_id = :user_id)
        ORDER BY ranked_players.rank
        LIMIT 5;
      SQL
      new(players.map(&method(:item_summary)))
    end

    private

    def attachment(text, doubles:)
      {
          text: text,
          footer_icon: doubles ? doubles_image_url : singles_image_url,
          footer: doubles ? 'Doubles' : 'Singles',
          ts: ts
      }
    end

    def model_class
      Player.select('players.*, dense_rank() over (order by rating desc) as rank')
    end

    def item_summary(player)
      "#{player.rank}. #{player.team_tag} (#{player.rating})"
    end
  end
end