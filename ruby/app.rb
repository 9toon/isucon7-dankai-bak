require 'newrelic_rpm'
require 'digest/sha1'
require 'mysql2'
require 'sinatra/base'
require 'redis'
require 'oj'

class App < Sinatra::Base
  configure do
    set :session_secret, 'tonymoris'
    set :public_folder, File.expand_path('../../public', __FILE__)
    set :icons_folder, "#{public_folder}/icons"
    set :avatar_max_size, 1 * 1024 * 1024

    enable :sessions
  end

  configure :development do
    require 'sinatra/reloader'
    register Sinatra::Reloader
  end

  helpers do
    def user
      return @_user unless @_user.nil?

      user_id = session[:user_id]
      return nil if user_id.nil?

      @_user = db_get_user(user_id)
      if @_user.nil?
        params[:user_id] = nil
        return nil
      end

      @_user
    end
  end

  get '/initialize' do
    db.query("DELETE FROM user WHERE id > 1000")
    db.query("DELETE FROM channel WHERE id > 10")
    db.query("DELETE FROM message WHERE id > 10000")
    db.query("DELETE FROM haveread")

    redis.flushdb
    redis.set(message_id_key, 0)

    import_message_to_redis

    #export_icons_to_public_dir

    204
  end

  get '/' do
    if session.has_key?(:user_id)
      return redirect '/channel/1', 303
    end
    erb :index
  end

  get '/channel/:channel_id' do
    if user.nil?
      return redirect '/login', 303
    end

    @channel_id = params[:channel_id].to_i
    @channels, @description = get_channel_list_info(@channel_id)
    erb :channel
  end

  get '/register' do
    erb :register
  end

  post '/register' do
    name = params[:name]
    pw = params[:password]
    if name.nil? || name.empty? || pw.nil? || pw.empty?
      return 400
    end
    begin
      user_id = register(name, pw)
    rescue Mysql2::Error => e
      return 409 if e.error_number == 1062
      raise e
    end
    session[:user_id] = user_id
    redirect '/', 303
  end

  get '/login' do
    erb :login
  end

  post '/login' do
    name = params[:name]
    statement = db.prepare('SELECT * FROM user WHERE name = ?')
    row = statement.execute(name).first
    if row.nil? || row['password'] != Digest::SHA1.hexdigest(row['salt'] + params[:password])
      return 403
    end
    session[:user_id] = row['id']
    redirect '/', 303
  end

  get '/logout' do
    session[:user_id] = nil
    redirect '/', 303
  end

  post '/message' do
    user_id = session[:user_id]
    message = params[:message]
    channel_id = params[:channel_id]
    if user_id.nil? || message.nil? || channel_id.nil? || user.nil?
      return 403
    end
    redis_add_message(channel_id.to_i, user_id, message)
    204
  end

  get '/message' do
    user_id = session[:user_id]
    if user_id.nil?
      return 403
    end

    channel_id = params[:channel_id].to_i
    last_message_id = params[:last_message_id].to_i
    rows = fetch_messages(channel_id, message_id: last_message_id, per_page: 100)

    user_ids = rows.map { |r| r[:user_id] }
    if !user_ids.empty?
      u_rows = db.query("SELECT user.id, user.name, user.display_name, user.avatar_icon FROM user WHERE user.id IN (#{user_ids.join(', ')})").to_a
    else
      u_rows = []
    end
    users = u_rows.each.with_object({}) do |user, hsh|
      hsh[user['id']] = {
        name: user['name'],
        display_name: user['display_name'],
        avatar_icon: user['avatar_icon'],
      }
    end

    response = []
    rows.each do |row|
      r = {}
      r['id'] = row[:id]
      r['user'] = users[row[:user_id]]
      r['date'] = row[:created_at].strftime("%Y/%m/%d %H:%M:%S")
      r['content'] = row[:content]
      response << r
    end
    response.reverse!

    max_message_id = rows.empty? ? 0 : rows.first[:id]
    save_haveread(user_id, channel_id, max_message_id)

    content_type :json
    Oj.dump(response)
  end

  get '/fetch' do
    user_id = session[:user_id]
    if user_id.nil?
      return 403
    end

    sleep 1.0

    rows = db.query('SELECT id FROM channel').to_a
    channel_ids = rows.map { |row| row['id'] }

    res = []
    channel_ids.each do |channel_id|
      message_id = fetch_haveread(user_id, channel_id)
      r = {}
      r['channel_id'] = channel_id
      r['unread'] = if message_id.nil?
        count_messages(channel_id)
      else
        count_messages(channel_id, message_id: message_id)
      end
      res << r
    end

    content_type :json
    Oj.dump(res)
  end

  get '/history/:channel_id' do
    if user.nil?
      return redirect '/login', 303
    end

    @channel_id = params[:channel_id].to_i

    @page = params[:page]
    if @page.nil?
      @page = '1'
    end
    if @page !~ /\A\d+\Z/ || @page == '0'
      return 400
    end
    @page = @page.to_i

    n = 20
    rows = fetch_messages(@channel_id, page: @page, per_page: n)
    @messages = []
    rows.each do |row|
      r = {}
      r['id'] = row[:id]
      statement = db.prepare('SELECT name, display_name, avatar_icon FROM user WHERE id = ?')
      r['user'] = statement.execute(row[:user_id]).first
      r['date'] = row[:created_at].strftime("%Y/%m/%d %H:%M:%S")
      r['content'] = row[:content]
      @messages << r
      statement.close
    end
    @messages.reverse!

    cnt = count_messages(@channel_id).to_f
    @max_page = cnt == 0 ? 1 :(cnt / n).ceil

    return 400 if @page > @max_page

    @channels, @description = get_channel_list_info(@channel_id)
    erb :history
  end

  get '/profile/:user_name' do
    if user.nil?
      return redirect '/login', 303
    end

    @channels, = get_channel_list_info

    user_name = params[:user_name]
    statement = db.prepare('SELECT * FROM user WHERE name = ?')
    @user = statement.execute(user_name).first
    statement.close

    if @user.nil?
      return 404
    end

    @self_profile = user['id'] == @user['id']
    erb :profile
  end

  get '/add_channel' do
    if user.nil?
      return redirect '/login', 303
    end

    @channels, = get_channel_list_info
    erb :add_channel
  end

  post '/add_channel' do
    if user.nil?
      return redirect '/login', 303
    end

    name = params[:name]
    description = params[:description]
    if name.nil? || description.nil?
      return 400
    end
    statement = db.prepare('INSERT INTO channel (name, description, updated_at, created_at) VALUES (?, ?, NOW(), NOW())')
    statement.execute(name, description)
    channel_id = db.last_id
    statement.close
    redirect "/channel/#{channel_id}", 303
  end

  post '/profile' do
    if user.nil?
      return redirect '/login', 303
    end

    if user.nil?
      return 403
    end

    display_name = params[:display_name]
    avatar_name = nil
    avatar_data = nil

    file = params[:avatar_icon]
    unless file.nil?
      filename = file[:filename]
      if !filename.nil? && !filename.empty?
        ext = filename.include?('.') ? File.extname(filename) : ''
        unless ['.jpg', '.jpeg', '.png', '.gif'].include?(ext)
          return 400
        end

        if settings.avatar_max_size < file[:tempfile].size
          return 400
        end

        data = file[:tempfile].read
        digest = Digest::SHA1.hexdigest(data)

        avatar_name = digest + ext
        avatar_data = data
      end
    end

    if !avatar_name.nil? && !avatar_data.nil?
      write_icon(avatar_name, avatar_data)
      statement = db.prepare('UPDATE user SET avatar_icon = ? WHERE id = ?')
      statement.execute(avatar_name, user['id'])
      statement.close
    end

    if !display_name.nil? || !display_name.empty?
      statement = db.prepare('UPDATE user SET display_name = ? WHERE id = ?')
      statement.execute(display_name, user['id'])
      statement.close
    end

    redirect '/', 303
  end

  private

  def db
    return @db_client if defined?(@db_client)

    @db_client = Mysql2::Client.new(
      host: ENV.fetch('ISUBATA_DB_HOST') { 'localhost' },
      port: ENV.fetch('ISUBATA_DB_PORT') { '3306' },
      username: ENV.fetch('ISUBATA_DB_USER') { 'root' },
      password: ENV.fetch('ISUBATA_DB_PASSWORD') { '' },
      database: 'isubata',
      encoding: 'utf8mb4'
    )
    @db_client.query('SET SESSION sql_mode=\'TRADITIONAL,NO_AUTO_VALUE_ON_ZERO,ONLY_FULL_GROUP_BY\'')
    @db_client
  end

  def redis
    return @redis if defined?(@redis)

    @redis = Redis.new(
      url: ENV.fetch('ISUBATA_REDIS_URL') { 'redis://localhost:6379/10' },
    )
    @redis
  end

  def db_get_user(user_id)
    statement = db.prepare('SELECT * FROM user WHERE id = ?')
    user = statement.execute(user_id).first
    statement.close
    user
  end

  def register(user, password)
    salt = 'a'
    pass_digest = Digest::SHA1.hexdigest(salt + password)
    statement = db.prepare('INSERT INTO user (name, salt, password, display_name, avatar_icon, created_at) VALUES (?, ?, ?, ?, ?, NOW())')
    statement.execute(user, salt, pass_digest, user, 'default.png')
    row = db.query('SELECT LAST_INSERT_ID() AS last_insert_id').first
    statement.close
    row['last_insert_id']
  end

  def get_channel_list_info(focus_channel_id = nil)
    @channels ||= db.query('SELECT id, name, description FROM channel ORDER BY id').to_a

    if focus_channel_id
      statement = db.prepare("SELECT description FROM channel WHERE id = ?")
      description = statement.execute(focus_channel_id).first['description']
      statement.close
    else
      description = ''
    end

    [@channels, description]
  end

  def redis_add_message(channel_id, user_id, content, created_at: Time.now)
    message_id = get_message_id

    store_message_entity(channel_id, message_id)
    store_message_content(message_id, channel_id, user_id, content, created_at)
  end

  def store_message_entity(channel_id, message_id)
    entity_key = message_entity_key(channel_id)
    content_key = message_content_key(channel_id, message_id)

    redis.zadd(entity_key, message_id, content_key)
  end

  def store_message_content(message_id, channel_id, user_id, content, created_at)
    content_key = message_content_key(channel_id, message_id)

    data = { id: message_id, user_id: user_id, content: content, created_at: created_at }
    redis.set(content_key, Oj.dump(data))
  end

  def get_message_id
    redis.incr(message_id_key)
  end

  def message_entity_key(channel_id)
    "message:entity:cid:#{channel_id}"
  end

  def message_content_key(channel_id, message_id)
    "message:content:cid:#{channel_id}:mid:#{message_id}"
  end

  def message_id_key
    "message:id"
  end

  def import_message_to_redis
    messages = db.query('SELECT id, channel_id, user_id, content, created_at FROM message ORDER BY id ASC')
    messages.each { |msg| redis_add_message(msg['channel_id'], msg['user_id'], msg['content'], created_at: msg['created_at']) }
  end

  def count_messages(channel_id, message_id: nil)
    if message_id.nil?
      redis.zcard(message_entity_key(channel_id))
    else
      redis.zcount(message_entity_key(channel_id), "(#{message_id}", "+inf")
    end
  end

  def fetch_messages(channel_id, message_id: nil, per_page: nil, page: 1)
    min = message_id ? message_id : 0
    option = per_page ? { limit: [[0, ((page.to_i - 1) * per_page) - 1].max, per_page] } : {}

    entity_key = message_entity_key(channel_id)
    content_keys = redis.zrevrangebyscore(entity_key, '+inf', "(#{min}", option)

    return [] if content_keys.empty?

    Array(redis.mget(*content_keys)).map { |str| Oj.load(str) }
  end

  def save_haveread(user_id, channel_id, message_id)
    redis.set(haveread_key(user_id, channel_id), message_id)
  end

  def fetch_haveread(user_id, channel_id)
    redis.get(haveread_key(user_id, channel_id))
  end

  def haveread_key(user_id, channel_id)
    "haveread:uid:#{user_id}:cid:#{channel_id}"
  end

  def write_icon(name, data)
    File.write("#{settings.icons_folder}/#{name}", data)
  end
end
