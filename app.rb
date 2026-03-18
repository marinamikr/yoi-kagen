require 'bundler/setup'
Bundler.require
require 'sinatra/reloader' if development?
require 'json'    
require 'line/bot'
require 'openai' 
require 'dotenv/load'
require 'sinatra/activerecord'
require 'google/apis/calendar_v3'
require './models'
require 'rufus-scheduler'
require 'net/http'

enable :sessions
set :session_secret, '8b4b1a41a4a2c5a2c91c89f5c490a6e344e21a2d48344e99f5a0cfb2e2d9b23f'

OmniAuth.config.full_host = lambda { |env| "#{env['rack.url_scheme']}://#{env['HTTP_HOST']}" }
OmniAuth.config.allowed_request_methods = [:post, :get]
OmniAuth.config.silence_get_warning = true

use OmniAuth::Builder do
  provider :line, ENV['LINE_LOGIN_CHANNEL_ID'], ENV['LINE_LOGIN_CHANNEL_SECRET'], provider_ignores_state: true
  
  provider :google_oauth2, ENV['GOOGLE_CLIENT_ID'], ENV['GOOGLE_CLIENT_SECRET'], {
    scope: 'email, profile, https://www.googleapis.com/auth/calendar.events',
    prompt: 'consent',
    access_type: 'offline',
    provider_ignores_state: true
  }
end


get '/' do
  erb :index
end

# LINEログイン後の処理
get '/auth/line/callback' do
  auth_data = request.env['omniauth.auth']
  user = User.find_or_create_by(line_user_id: auth_data[:uid])
  
  user.update(
    name: auth_data[:info][:name],
    profile_image_url: auth_data[:info][:image]
  )

  session[:user_name] = user.name
  session[:user_image] = user.profile_image_url
  session[:line_user_id] = user.line_user_id
  
  redirect '/mypage'
end

# Google連携が完了したあとの処理
get '/auth/google_oauth2/callback' do
 redirect '/' if session[:line_user_id].nil?

  auth_data = request.env['omniauth.auth']
  user = User.find_by(line_user_id: session[:line_user_id])
  
  if user
    user.update(
      google_token: auth_data.credentials.token,
      google_refresh_token: auth_data.credentials.refresh_token || user.google_refresh_token
    )
  end

  session[:google_token] = auth_data.credentials.token
  redirect '/mypage'
end

get '/mypage' do
  redirect '/' if session[:line_user_id].nil?
  @logs = AnalysisLog.where(line_user_id: session[:line_user_id]).order(created_at: :desc)
  erb :mypage
end

get '/current' do
  redirect '/' if session[:line_user_id].nil?
  @logs = AnalysisLog.where(line_user_id: session[:line_user_id]).order(created_at: :desc)
  latest_log = @logs.first
  
  if latest_log && (Time.now.utc - latest_log.created_at) <= 2 * 60 * 60
    @current_score = latest_log.yoi_score
  else
    @current_score = 0
  end

  @current_emoji = case @current_score
                   when 0 then "😀"
                   when 1..30 then "😆"
                   when 31..79 then "🫠"
                   else "🤮"
                   end
  erb :current
end

get '/week_meter' do
  redirect '/' if session[:line_user_id].nil?
  
  today = Date.today
  monday = today - today.wday + (today.wday == 0 ? -6 : 1)
  days_of_week_ja = ['月', '火', '水', '木', '金', '土', '日']
  @weekly_scores = {}
  
  7.times do |i|
    target_date = monday + i
    target_day_name_ja = days_of_week_ja[i]
    logs_on_date = AnalysisLog.where(line_user_id: session[:line_user_id], created_at: target_date.beginning_of_day..target_date.end_of_day)
    max_score = logs_on_date.maximum(:yoi_score) || 0
    @weekly_scores[target_day_name_ja] = max_score
  end

  @risky_events = []
  if session[:google_token]
    begin
      service = Google::Apis::CalendarV3::CalendarService.new
      service.authorization = session[:google_token]
      
      past_time_limit = Time.now.utc - 60 * 24 * 60 * 60
      past_logs = AnalysisLog.where(line_user_id: session[:line_user_id]).where("created_at >= ?", past_time_limit)
      
      daily_max_scores = {}
      past_logs.each do |log|
        jst_time = log.created_at + (9 * 60 * 60)
        date_str = jst_time.strftime("%Y-%m-%d")
        daily_max_scores[date_str] = [daily_max_scores[date_str] || 0, log.yoi_score].max
      end

      now_iso = Time.now.utc.iso8601
      past_events = service.list_events('primary', time_min: past_time_limit.iso8601, time_max: now_iso, single_events: true, max_results: 2500).items
      
      event_risk_history = {}
      past_events.each do |event|
        title = event.summary
        next if title.nil? || title.empty?
        clean_title = title.strip
        
        if event.start.date_time
          date_str = (event.start.date_time.to_time + (9 * 60 * 60)).strftime("%Y-%m-%d")
        else
          date_str = event.start.date.to_s
        end
        
        score = daily_max_scores[date_str] || 0
        event_risk_history[clean_title] ||= []
        event_risk_history[clean_title] << score
      end

      tomorrow_iso = (Time.now.utc + 24 * 60 * 60).iso8601
      upcoming_events = service.list_events('primary', time_min: now_iso, time_max: tomorrow_iso, single_events: true, order_by: 'startTime').items
      
      upcoming_events.each do |event|
        title = event.summary
        next if title.nil? || title.empty?
        clean_title = title.strip
        
        scores = event_risk_history[clean_title]
        if scores && scores.any?
          max_past_score = scores.max
          if max_past_score >= 80
            start_time_str = event.start.date_time ? (event.start.date_time.to_time + (9 * 60 * 60)).strftime("%H:%M") : "終日"
            unless @risky_events.any? { |e| e["title"] == clean_title }
              @risky_events << { "title" => clean_title, "risk_score" => max_past_score, "start_time" => start_time_str }
            end
          end
        end
      end
    rescue => e
      puts "カレンダー取得エラー: #{e.class} - #{e.message}"
    end
  end

  erb :week_meter
end

get '/friends' do
  redirect '/' if session[:line_user_id].nil?
  @friends_data = User.where.not(name: nil).where.not(name: "").map do |user|
    latest_log = AnalysisLog.where(line_user_id: user.line_user_id)
                            .where("created_at > ?", Time.now.utc - 2*60*60)
                            .order(created_at: :desc).first
                            
                            display_name = user.name.nil? || user.name.empty? ? "未ログインの友達" : user.name
display_image = user.profile_image_url.present? ? user.profile_image_url : "/images/logo.png"
    {
      name: user.name,
      image: user.profile_image_url,
      score: latest_log ? latest_log.yoi_score : 0,
      id: user.line_user_id
    }
  end
  erb :friends
end

post '/invite' do
  target_id = params[:line_user_id]
  message = {
    type: 'text',
    text: "#{session[:user_name]}さんからお誘いです！\n「飲みに行こうよ！」"
  }
  client.push_message(target_id, message)
user_agent = request.user_agent.to_s.downcase
  
  is_mobile = user_agent.match?(/iphone|android.+mobile|windows phone/)

  if is_mobile
    redirect '/week_meter'
  else
    redirect '/dashboard'
  end
end

get '/dashboard' do
  redirect '/' if session[:line_user_id].nil?
  
  # ① 今週の酔い度メーター用のデータ取得
  today = Date.today
  monday = today - (today.cwday - 1)
  days_of_week_ja = ['月', '火', '水', '木', '金', '土', '日']
  @weekly_scores = {}
  
  7.times do |i|
    target_date = monday + i
    day_name = days_of_week_ja[i]
    max_score = AnalysisLog.where(
      line_user_id: session[:line_user_id], 
      created_at: target_date.all_day
    ).maximum(:yoi_score) || 0
    @weekly_scores[day_name] = max_score
  end

  @friends_data = User.where.not(name: nil).where.not(name: "").map do |user|
    latest_log = AnalysisLog.where(line_user_id: user.line_user_id)
                            .where("created_at > ?", Time.now.utc - 2*60*60)
                            .order(created_at: :desc).first
                            
    display_name = user.name.nil? || user.name.empty? ? "未ログインの友達" : user.name
display_image = user.profile_image_url.present? ? user.profile_image_url : "/images/logo.png"
{
      name: display_name,  
      image: display_image, 
      score: latest_log ? latest_log.yoi_score : 0,
      id: user.line_user_id
    }
  end

  @risky_events = []
  user = User.find_by(line_user_id: session[:line_user_id])
  current_token = user ? (refresh_google_token(user) || user.google_token || session[:google_token]) : session[:google_token]
  if session[:google_token]
    begin
      service = Google::Apis::CalendarV3::CalendarService.new
      service.authorization = session[:google_token]
      
      past_time_limit = Time.now.utc - 60 * 24 * 60 * 60 # 60日前
      past_logs = AnalysisLog.where(line_user_id: session[:line_user_id])
                             .where("created_at >= ?", past_time_limit)
      
      daily_max_scores = {}
      past_logs.each do |log|
        jst_time = log.created_at + (9 * 60 * 60)
        date_str = jst_time.strftime("%Y-%m-%d")
        daily_max_scores[date_str] = [daily_max_scores[date_str] || 0, log.yoi_score].max
      end

      now_iso = Time.now.utc.iso8601
      past_events = service.list_events('primary', time_min: past_time_limit.iso8601, time_max: now_iso, single_events: true, max_results: 2500).items
      
      event_risk_history = {}
      past_events.each do |event|
        title = event.summary
        next if title.nil? || title.empty?
        clean_title = title.strip
        
        if event.start.date_time
          date_str = (event.start.date_time.to_time + (9 * 60 * 60)).strftime("%Y-%m-%d")
        else
          date_str = event.start.date.to_s
        end
        
        score = daily_max_scores[date_str] || 0
        
        event_risk_history[clean_title] ||= []
        event_risk_history[clean_title] << score
      end

      tomorrow_iso = (Time.now.utc + 24 * 60 * 60).iso8601
      upcoming_events = service.list_events('primary', time_min: now_iso, time_max: tomorrow_iso, single_events: true, order_by: 'startTime').items
      
      upcoming_events.each do |event|
        title = event.summary
        next if title.nil? || title.empty?
        clean_title = title.strip
        
        scores = event_risk_history[clean_title]
        if scores && scores.any?
          max_past_score = scores.max
          if max_past_score >= 80
            start_time_str = event.start.date_time ? (event.start.date_time.to_time + (9 * 60 * 60)).strftime("%H:%M") : "終日"
            
            unless @risky_events.any? { |e| e["title"] == clean_title }
              @risky_events << {
                "title" => clean_title,
                "risk_score" => max_past_score,
                "start_time" => start_time_str
              }
            end
          end
        end
      end
    rescue => e
      puts "カレンダー取得エラー: #{e.class} - #{e.message}"
    end
  end

  erb :dashboard
end

get '/logout' do
  session.clear
  redirect '/'
end


def client
  @client ||= Line::Bot::Client.new { |config|
    config.channel_secret = ENV['LINE_CHANNEL_SECRET']
    config.channel_token  = ENV['LINE_CHANNEL_TOKEN']
  }
end

def refresh_google_token(user)
  return nil unless user.google_refresh_token

  uri = URI.parse("https://oauth2.googleapis.com/token")
  response = Net::HTTP.post_form(uri, {
    "client_id" => ENV['GOOGLE_CLIENT_ID'],
    "client_secret" => ENV['GOOGLE_CLIENT_SECRET'],
    "refresh_token" => user.google_refresh_token,
    "grant_type" => "refresh_token"
  })
  
  data = JSON.parse(response.body)
  if data["access_token"]
    user.update(google_token: data["access_token"])
    return data["access_token"]
  end
  nil
end

def openai_client
  @openai_client ||= OpenAI::Client.new(access_token: ENV['OPENAI_API_KEY'])
end


post '/callback' do
  body = request.body.read
  signature = request.env['HTTP_X_LINE_SIGNATURE']

  unless client.validate_signature(body, signature)
    halt 400, 'Bad Request'
  end

  events = client.parse_events_from(body)

  events.each do |event|
    case event
    when Line::Bot::Event::Message
      case event.type
      when Line::Bot::Event::MessageType::Text
        user_text = event.message['text']
        message_id = event.message['id'] 
        quoted_id = event.message['quotedMessageId'] 
        
        user_id = event['source']['userId']
        group_id = event['source']['groupId']
        room_id = event['source']['roomId']
        chat_id = group_id || room_id || user_id

        user = User.find_or_create_by(line_user_id: user_id)
        chat_session = User.find_or_create_by(line_user_id: chat_id)

        memory_file = "recent_messages.json"
        recent_messages = {}
        if File.exist?(memory_file)
          recent_messages = JSON.parse(File.read(memory_file)) rescue {}
        end

        if user_text.delete(" 　").include?("/シラフにして")
          if quoted_id && recent_messages[quoted_id]
            target_msg = recent_messages[quoted_id]
            reply_text = "🔎 【シラフにしてみた！】\n"
            reply_text += "元の発言:「#{target_msg['original']}」\n\n"
            reply_text += "✨ シラフ翻訳:#{target_msg['sober']}"
            client.reply_message(event['replyToken'], { type: 'text', text: reply_text })
          else
            last_log = AnalysisLog.order(created_at: :desc).first 
            if last_log
              reply_text = "🔎 【シラフにしてみた！】\n"
              reply_text += "元の発言:「#{last_log.original_text}」\n\n"
              reply_text += "✨ シラフ翻訳:#{last_log.sober_text}"
              client.reply_message(event['replyToken'], { type: 'text', text: reply_text })
            end
          end
          next
        elsif ["/nomikai", "/飲み会", "/のみかい"].include?(user_text.delete(" 　"))
          chat_session.update(status: "on")
          client.reply_message(event['replyToken'], { type: 'text', text: "🍻 グループの酔い加減測定モード【ON】🍻\nどんどん喋ってね！" })
          next
        elsif ["/neru", "/寝る", "/ねる"].include?(user_text.delete(" 　"))
          chat_session.update(status: "off")
          client.reply_message(event['replyToken'], { type: 'text', text: "😴 酔い加減測定モード【OFF】😴\nねなさい！！" })
          next
        else
          prompt = <<~PROMPT
            あなたは「酔っ払い度判定AI」です。
            ユーザーの送信した文章を分析し、以下の【厳格な判定基準】に従って「酔い度（yoi_score）」を0〜100の数値で判定し、元の意味を推測した「シラフ翻訳（sober_text）」と一緒にJSON形式で返してください。

            【厳格な判定基準】
            - 0% : 誤字脱字がなく、文法も意味も完璧でまともな文章。（例：「今から帰ります」「お疲れ様です」「さっきよりいい感じかも？」）
            - 20% : 基本的に意味は通じるが、1文字程度の軽い誤字や、フリック入力のわずかなミスがある文章。（例：「いまからかえりまう」「あしたよろいくー」）
            - 40〜60% : 複数の誤字、文脈がおかしい、助詞が抜けている、テンションが異常に高い文章。（例：「あしアはよろいく！」「いまえきなんあけど、でんしゃない」「やあすぎる」）
            - 80〜100% : 支離滅裂、意味不明な文字列、ひらがなや記号の異常な連続、完全に酔い潰れている状態。（例：「ああああああww」「かえええんてれえ」「ぅぅぅ、んｊ」）

            【分析する文章】
            「#{user_text}」

            【出力形式（必ず以下のJSONのみを出力すること）】
            {
              "yoi_score": (数値),
              "sober_text": "(推測されるシラフ状態の文章)"
            }
          PROMPT

          response = openai_client.chat(parameters: { model: "gpt-4o-mini", response_format: { type: "json_object" }, messages: [{ role: "user", content: prompt }] })
          ai_result = JSON.parse(response.dig("choices", 0, "message", "content"))
          
          log = AnalysisLog.create(
            line_user_id: user_id,
            original_text: user_text,
            sober_text: ai_result["sober_text"],
            yoi_score: ai_result["yoi_score"]
          )

          recent_messages[message_id] = {
            "original" => user_text,
            "sober" => ai_result["sober_text"]
          }
          recent_messages.shift if recent_messages.size > 100
          File.write(memory_file, recent_messages.to_json)

          if chat_session.status == "on"
            reply_text = "🍺 酔い度: #{log.yoi_score}%"
            client.reply_message(event['replyToken'], { type: 'text', text: reply_text })
          end
        end
      end
    end
  end
  "OK"
end

##通知
scheduler = Rufus::Scheduler.new

scheduler.every '10m' do
  puts "🤖 [自動] カレンダーチェックします"
  
  User.where.not(google_token: nil).each do |user|
    begin
      current_token = refresh_google_token(user) || user.google_token
      service = Google::Apis::CalendarV3::CalendarService.new
      service.authorization = current_token

      now = Time.now
      
      past_time_limit = now.utc - 60 * 24 * 60 * 60
      past_logs = AnalysisLog.where(line_user_id: user.line_user_id).where("created_at >= ?", past_time_limit)
      
      daily_max_scores = {}
      past_logs.each do |log|
        jst_time = log.created_at + (9 * 60 * 60)
        daily_max_scores[jst_time.strftime("%Y-%m-%d")] = [daily_max_scores[jst_time.strftime("%Y-%m-%d")] || 0, log.yoi_score].max
      end

      past_events = service.list_events('primary', time_min: past_time_limit.iso8601, time_max: now.utc.iso8601, single_events: true, max_results: 2500).items
      event_risk_history = {}
      past_events.each do |event|
        title = event.summary
        next if title.nil? || title.empty?
        
        date_str = event.start.date_time ? (event.start.date_time.to_time + (9 * 60 * 60)).strftime("%Y-%m-%d") : event.start.date.to_s
        score = daily_max_scores[date_str] || 0
        
        event_risk_history[title.strip] ||= []
        event_risk_history[title.strip] << score
      end

      upcoming_events = service.list_events('primary', time_min: now.utc.iso8601, time_max: (now + 60 * 60).utc.iso8601, single_events: true).items
      
      upcoming_events.each do |event|
        next unless event.start.date_time
        
        event_time = event.start.date_time.to_time
        time_diff = event_time - now
        
        if time_diff >= 25 * 60 && time_diff <= 35 * 60
          clean_title = event.summary.strip
          scores = event_risk_history[clean_title]
          
          if scores && scores.any?
            max_past_score = scores.max
            
            if max_past_score >= 80
              message_text = "【⚠️飲み過ぎ注意⚠️】️\n\n約30分後に「#{clean_title}」\n過去のこの予定では【酔い度 #{max_past_score}%】」\nを記録！🍋\n\n飲み過ぎ注意！！！"
              
              client.push_message(user.line_user_id, { type: 'text', text: message_text })
              puts "🚨 #{user.name}さんに警告LINEを送信しました！"
            end
          end
        end
      end
    rescue => e
      puts "❌ #{user.name} の自動通知チェックでエラー: #{e.message}"
    end
  end
end
