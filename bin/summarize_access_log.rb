require 'mustermann'
require 'table_print'

ROUTES = [
  { get: '/initialize' },
  { get: '/' },
  { get: '/channel/:channel_id' },
  { get: '/register' },
  { post: '/register' },
  { get: '/login' },
  { post: '/login' },
  { get: '/logout' },
  { post: '/message' },
  { get: '/fetch' },
  { get: '/history/:channel_id' },
  { get: '/profile/:user_name' },
  { get: '/profile' },
  { post: '/profile' },
  { get: '/add_channel' },
  { post: '/add_channel' },
  { get: '/icons/:file_name' },
]

LOG_FILE_PATH = 'tmp/access.log'

class Summarizer
  def initialize
    @routes = ROUTES.map do |route|
      {
        method: route.keys[0].to_s.upcase,
        path: Mustermann.new(route.values[0]),
      }
    end
  end

  def print_as_markdown
    summarized = summarize
    tp summarized, except: :durations
  end

  def summarize
    File.readlines(LOG_FILE_PATH).map { |line|
      Hash[line.strip.split("\t").map{|f| f.split(":", 2)}]
    }
      .inject({}) { |memo, line|
      method, path = detect_route(line['method'], line['uri'])
      duration = line['apptime'] == '-' ? 0 : line['apptime'].to_f
      key = [method, path].join(':')

      memo[key] ||= { method: method, path: path, durations: [] }
      memo[key][:durations] << duration
      memo
    }
      .map { |_, line|
      line.merge(aggregate(line[:durations]))
    }
      .sort_by { |line|
      -line[:sum]
    }
  end

  def detect_route(method, uri)
    method = method.upcase
    path = uri.split('?')[0]

    route = @routes.find do |r|
      method == r[:method] && r[:path] === path
    end

    [method, route ? route[:path].to_s : path]
  end

  def aggregate(durations)
    count = durations.size
    sum = durations.reduce(&:+).round(3)

    {
      count: count,
      sum: sum,
      average: (sum / count).round(3),
      max: durations.max,
      min: durations.min,
    }
  end
end

Summarizer.new.print_as_markdown
