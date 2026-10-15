# Remixes: searches Remix.Kwed.Org (RKO, remix.kwed.org), the big archive
# of C64 music remixes, and answers in a few lines.
#
#   REMIX <words>                  the best-rated remixes matching (title, arranger or composer)
#   REMIX NEW [words]              the newest ones (matching, or on the whole site)
#   REMIX TOP [week|month|alltime] RKO's most popular
#   REMIX RANDOM [words]           one remix at random (matching, or any)
#   REMIX ID <number|link>         one remix in detail, with its original SID
#
# With a prefix in config.yml (prefix: "!"), !remix works in channels.
# Only RKO's normal pages are fetched, a few per command and with the bot's
# own user agent, and kept for a while (docs/remix.md).
#
# Install: bin/gemdrop-docker plugin install contrib/plugins/remix.rb
require "cgi"
require "uri"

class Remix < Gemdrop::Plugin
  description "Searches Remix.Kwed.Org for C64 remixes"
  help_group "Music"

  setting "results", default: 3, type: :integer, min: 1, max: 5, channel: true,
                     desc: "remixes per answer (plus one line saying what was found)"
  setting "title_length", default: 70, type: :integer, min: 20, max: 200, channel: true
  setting "per_channel_per_minute", default: 6, type: :integer, min: 1, max: 60, channel: true
  setting "cache_minutes", default: 10, type: :integer, min: 0, max: 1440

  SITE = "https://remix.kwed.org"
  PER_PAGE = 50
  MAX_QUERY = 30 # RKO's search field takes 30 characters
  CHARTS = %w[week month alltime].freeze
  CACHE_SIZE = 100

  # One remix, as a row of RKO's tables shows it.
  Row = Struct.new(:id, :date, :title, :arranger, :composer, :rating, :size, :length, :downloads, :sid,
                   keyword_init: true)

  command "REMIX", usage: "REMIX <words> | NEW [words] | TOP [week|month|alltime] | RANDOM [words] | ID <number|link>",
                   help: "C64 remixes from Remix.Kwed.Org", cooldown: 5,
                   details: "REMIX <words>: the best-rated remixes matching a title, arranger or composer.\n" \
                            "REMIX NEW [words]: the newest. REMIX TOP [week|month|alltime]: RKO's chart.\n" \
                            "REMIX RANDOM [words]: one at random. REMIX ID <number|link>: one in detail, " \
                            "with its original SID." do |ctx, args|
    ctx.usage! if args.empty?
    if ctx.channel? && !rate_limit("channel:#{casefold(ctx.channel)}", limit: settings_for(ctx.channel)["per_channel_per_minute"],
                                                                         per: 60)
      raise Gemdrop::Error, "Easy, a few remixes a minute here; try again shortly."
    end

    words = args.drop(1).join(" ")
    job = case args.first.upcase
          when "NEW" then check_query!(words) && -> { newest(ctx, words) }
          when "RANDOM" then check_query!(words) && -> { random(ctx, words) }
          when "TOP"
            period = words.empty? ? "week" : words.downcase
            raise Gemdrop::Error, "TOP takes week, month or alltime." unless CHARTS.include?(period)

            -> { chart(ctx, period) }
          when "ID"
            id = remix_id(words) or raise Gemdrop::Error, "ID takes a remix's number or its remix.kwed.org/remix/... link."
            -> { one(ctx, id) }
          else check_query!(ctx.text) && -> { search(ctx, ctx.text) }
          end
    queued = background do
      job.call
    rescue Gemdrop::Error => e
      ctx.reply_privately("Remix.Kwed.Org: #{e.message}")
    end
    raise Gemdrop::Error, "Busy right now; try again in a moment." unless queued
  end

  def setup
    @cache = {}
    @lock = Mutex.new
  end

  # --- the answers -------------------------------------------------------------------

  def search(ctx, words)
    found = find(words, view: "rating", count: true)
    return ctx.reply("RKO: no remixes of \"#{words}\". Fewer or other words may find some.") if found[:rows].empty?

    total = found[:total]
    head = "RKO: #{'at least ' if found[:at_least]}#{plural(total, 'remix')} of \"#{words}\"#{', best rated' if total > 1}"
    answer(ctx, head, found[:rows], more: total > shown(ctx) || found[:at_least] ? search_url(found[:query]) : nil)
  end

  def newest(ctx, words)
    return answer(ctx, "RKO: the newest remixes", page(view: "date")[:rows], dates: true, more: SITE) if words.empty?

    found = find(words, view: "date")
    return ctx.reply("RKO: no remixes of \"#{words}\".") if found[:rows].empty?

    answer(ctx, "RKO: the newest remixes of \"#{words}\"", found[:rows], dates: true, more: search_url(found[:query]))
  end

  def chart(ctx, period)
    rows = parse_chart(fetch("#{SITE}/?#{URI.encode_www_form('page' => 1, 'chart' => period, 'view' => 'date')}"))
    return ctx.reply("RKO: nothing popular #{period == 'alltime' ? 'of all time' : "this #{period}"} right now.") if rows.empty?

    answer(ctx, "RKO: the most popular #{period == 'alltime' ? 'of all time' : "this #{period}"}", rows,
           more: "#{SITE}/?chart=#{period}")
  end

  def random(ctx, words)
    row = words.empty? ? random_any : random_matching(words)
    return ctx.reply("RKO: no remixes of \"#{words}\".") unless row

    detail(ctx, row, head: words.empty? ? "RKO, at random:" : "RKO, at random for \"#{words}\":")
  end

  def one(ctx, id)
    row = remix(id) or return ctx.reply_privately("Remix.Kwed.Org has no remix #{id}.")
    detail(ctx, row)
  end

  def remix_id(text)
    (text[%r{remix\.kwed\.org/remix/(\d+)}i, 1] || text[/\A\s*#?(\d+)\s*\z/, 1])&.to_i
  end

  # --- what gets said ------------------------------------------------------------------

  def shown(ctx) = settings_for(ctx.channel)["results"]

  # A line about what was found, then one line per remix.
  def answer(ctx, head, rows, more: nil, dates: false)
    opts = settings_for(ctx.channel)
    list = rows.first(opts["results"])
    ctx.reply("#{head}#{": #{more}" if more}")
    list.each_with_index { |row, i| ctx.reply("#{i + 1}. #{summary(row, opts, date: dates)}") }
  end

  def summary(row, opts, date: false)
    parts = ["#{cut(row.title, opts['title_length'])} – #{row.arranger}#{" (#{row.composer})" if row.composer}"]
    parts << row.date if date && row.date
    parts << row.rating if row.rating
    parts << row.length if row.length
    parts << "#{SITE}/remix/#{row.id}"
    parts.join(" · ")
  end

  # Two lines: what it is, then where to hear it and its original SID.
  def detail(ctx, row, head: nil)
    opts = settings_for(ctx.channel)
    facts = [row.date && "out #{row.date}", row.length, row.size, row.downloads && plural(row.downloads, 'download'),
             row.rating].compact
    ctx.reply("#{"#{head} " if head}#{cut(row.title, opts['title_length'])} – #{row.arranger}" \
              "#{", original by #{row.composer}" if row.composer}#{" · #{facts.join(' · ')}" if facts.any?}")
    ctx.reply("Listen: #{SITE}/remix/#{row.id}#{" · SID: #{row.sid}" if row.sid}")
  end

  def cut(text, length) = text.length > length ? "#{text[0, length - 1].rstrip}…" : text

  PLURALS = { "remix" => "remixes", "download" => "downloads" }.freeze

  def plural(count, word) = "#{count} #{count == 1 ? word : PLURALS.fetch(word)}"

  # --- RKO's pages -----------------------------------------------------------------------

  def check_query!(words)
    raise Gemdrop::Error, "Search for at most #{MAX_QUERY} characters (RKO's limit)." if words.length > MAX_QUERY

    true
  end

  def search_url(words) = "#{SITE}/search/#{URI.encode_www_form_component(words)}"

  # One page of a list: { rows:, pages: }. view: rating or date; chart:
  # week, month or alltime; search: words.
  def page(view: nil, chart: "", search: nil, number: 1)
    query = { "page" => number, "chart" => chart }
    query["view"] = view if view
    query["search"] = search if search
    parse_list(fetch("#{SITE}/?#{URI.encode_www_form(query)}"))
  end

  FALLBACK_PAGES = 3

  # RKO matches the words as one phrase, punctuation and all ("Ghosts'n
  # Goblins" is stored escaped, "Glyn R Brown" has no dot). So: the words as
  # typed; else without punctuation; else the longest word's results, kept
  # where every word is in the title, arranger or composer. Returns rows
  # (best first by view), the query that found them, and with count: the
  # total (at_least when there were more pages than were read).
  def find(words, view:, count: false)
    tried = []
    [words, normalize(words)].uniq.each do |query|
      next if query.empty? || tried.include?(query.downcase)

      tried << query.downcase
      first = page(view: view, search: query)
      next if first[:rows].empty?

      return { rows: first[:rows], query: query, pages: first[:pages],
               total: count ? self.count(first, view: view, search: query) : nil }
    end
    narrowed(normalize(words).split, view, tried)
  end

  def narrowed(wanted, view, tried)
    key = wanted.max_by(&:length)
    none = { rows: [], query: nil, pages: 0, total: 0 }
    return none if wanted.size < 2 || key.length < 3 || tried.include?(key)

    first = page(view: view, search: key)
    rows = first[:rows].dup
    (2..[first[:pages], FALLBACK_PAGES].min).each { |n| rows.concat(page(view: view, search: key, number: n)[:rows]) }
    rows.select! { |row| has_all?(row, wanted) }
    { rows: rows, query: key, pages: 1, total: rows.size, at_least: first[:pages] > FALLBACK_PAGES && rows.any? }
  end

  def has_all?(row, wanted)
    hay = normalize([row.title, row.arranger, row.composer].compact.join(" "))
    tokens = hay.split
    wanted.all? { |word| word.length <= 2 ? tokens.include?(word) : hay.include?(word) }
  end

  def normalize(text) = text.to_s.downcase.gsub(/[^[:alnum:]]+/, " ").strip

  # How many a search found: PER_PAGE a page, and what the last page has.
  def count(first, **list)
    return first[:rows].size if first[:pages] <= 1

    last = page(**list, number: first[:pages])
    (PER_PAGE * (first[:pages] - 1)) + last[:rows].size
  end

  def random_matching(words)
    found = find(words, view: "rating")
    return nil if found[:rows].empty?

    number = rand(1..found[:pages])
    rows = number == 1 ? found[:rows] : page(view: "rating", search: found[:query], number: number)[:rows]
    rows.sample || found[:rows].sample
  end

  # Remixes are numbered; a few numbers are gone, so a few tries.
  def random_any
    newest = page(view: "date")[:rows].map(&:id).max or return nil
    4.times do
      row = remix(rand(1..newest))
      return row if row
    end
    nil
  end

  def remix(id) = parse_list(fetch("#{SITE}/remix/#{id}"))[:rows].find { |row| row.id == id }

  def fetch(url)
    ttl = settings["cache_minutes"] * 60
    hit = @lock.synchronize { @cache[url] }
    return hit[0] if hit && hit[1] > now

    response = http_get(url, accept: "text/html", types: /html/)
    raise Gemdrop::Error, "it answered #{response.status}; try again later." unless response.status == 200

    body = response.body.to_s.dup.force_encoding(Encoding::UTF_8).scrub
    if ttl.positive?
      @lock.synchronize do
        @cache[url] = [body, now + ttl]
        @cache.delete(@cache.keys.first) while @cache.size > CACHE_SIZE
      end
    end
    body
  end

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  # The remixes in a page of RKO's tables, and how many pages the list has.
  def parse_list(html)
    rows = html.scan(%r{<tr[^>]*>(.*?)</tr>}m).filter_map { |(row)| parse_row(row) }
    pages = html.scan(/[?&;]page=(\d+)/).flatten.map(&:to_i).max || 1
    { rows: rows, pages: [pages, 1].max }
  end

  # RKO's "What's popular?" box: rank, the title (the download link, with
  # size, length and downloads) and the arranger, the rating. Single quotes.
  def parse_chart(html)
    box = html[/Begin: Chart body(.*?)<\/tbody>/m, 1] or return []
    box.scan(%r{<tr[^>]*>(.*?)</tr>}m).filter_map do |(cells)|
      link = cells.match(%r{<a[^>]*title=['"]([^'"]*)['"][^>]*href=['"]/download\.php/(\d+)/[^'"]*['"][^>]*>(.*?)</a>(?:<br\s*/?>)?([^<]*)}m)
      next unless link

      size, length, downloads = link[1].split(" / ").map(&:strip)
      Row.new(id: link[2].to_i, title: text(link[3]), arranger: text(link[4]),
              rating: cells[/class=['"]vote['"][^>]*title=['"]([^'"]*)['"]/, 1]&.then { |r| unescape(r) },
              size: size.to_s.empty? ? nil : size.sub(/\s*Mb\z/i, " MB"), length: length&.sub(/\s*minutes?\z/, ""),
              downloads: downloads&.[](/\d+/)&.to_i)
    end
  end

  # Cells: date (with the permalink), title (the download link, with size,
  # length and downloads in its title), arranger, composer, icons (rating,
  # the original SID on DeepSID).
  def parse_row(html)
    id = html[%r{href="/remix/(\d+)"}, 1] or return nil
    cells = html.scan(%r{<td[^>]*>(.*?)</td>}m).flatten
    return nil if cells.size < 4

    info = html[/title="([^"]*)"[^>]*class="download"/, 1] || html[/class="download"[^>]*title="([^"]*)"/, 1]
    size, length, downloads = info.to_s.split(" / ").map(&:strip)
    Row.new(id: id.to_i, date: iso_date(text(cells[0])), title: text(cells[1]), arranger: text(cells[2]),
            composer: text(cells[3]).then { |c| c.empty? ? nil : c },
            rating: html[/class="vote"[^>]*title="([^"]*)"/, 1]&.then { |r| unescape(r) },
            size: size.to_s.empty? ? nil : size.sub(/\s*Mb\z/i, " MB"),
            length: length&.sub(/\s*minutes?\z/, ""),
            downloads: downloads&.[](/\d+/)&.to_i,
            sid: html[/class="sid"[^>]*href="([^"]+)"/, 1]&.then { |u| unescape(u) })
  end

  # RKO writes dates as dd/mm/yy.
  def iso_date(text)
    match = text.match(%r{\A(\d\d)/(\d\d)/(\d\d)\z}) or return nil
    "20#{match[3]}-#{match[2]}-#{match[1]}"
  end

  def text(html) = unescape(html.to_s.gsub(/<[^>]*>/, " ")).gsub(/\s+/, " ").strip

  def unescape(text) = CGI.unescapeHTML(text.to_s)
end
