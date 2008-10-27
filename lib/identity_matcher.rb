module IdentityMatcher
    module Methods
        # included is called from the ActiveRecord::Base
        # when you inject this module

        def self.included(base) 
            # Add acts_as_roled availability by extending the module
            # that owns the function.
            base.extend AddMatchesMethod
        end 

        # this module stores the main function and the two modules for
        # the instance and class functions
        module AddMatchesMethod
            def matches_identities(options = {})
                # Here you can put additional association for the
                # target class.
                # belongs_to :role
                # add class and istance methods
                cattr_accessor :im_options
                self.im_options = options
                self.im_options[:nickname_field]  ||= :nick
                self.im_options[:email_field]     ||= :email

         class_eval <<-END
           include IdentityMatcher::Methods::InstanceMethods    
         END
            end

            def match_foaf(foaf_xml)
                require 'open3'
                foaf = {}
                cmd = "xsltproc #{RAILS_ROOT}/lib/rdfc14n.xsl - | xsltproc #{RAILS_ROOT}/lib/rdfc2nt.xsl -"
                ntriples = nil
                Open3.popen3(cmd) do |stdin,stdout,stderr| 
                    stdin.write(foaf_xml)
                    stdin.close
                    ntriples = stdout.read
                end
                if ntriples.nil?
                    return []
                end
                ntriples.split(/\n/).each { |line|
                    if line.match(/(.*) (<.*>) (.*) \./)
                        if !foaf.has_key?($1)
                            foaf[$1] = {}
                        end
                        if !foaf[$1].has_key?($2)
                            foaf[$1][$2] = []
                        end
                        foaf[$1][$2] << $3
                    end
                }
                nicks = []
                names = []
                if foaf.has_key? '<>'
                    knows = foaf['<>']["<http://xmlns.com/foaf/0.1/knows>"]
                    if !knows.nil?
                        knows.each do |know|
                            if foaf.has_key? know
                                person_id = foaf[know]["<http://xmlns.com/foaf/0.1/Person>"]
                                if !person_id.nil? and person_id.size > 0
                                    person = foaf[person_id[0]]
                                    if !person['<http://xmlns.com/foaf/0.1/nick>'].nil? and person['<http://xmlns.com/foaf/0.1/nick>'].size > 0
                                        nicks << person['<http://xmlns.com/foaf/0.1/nick>'][0]
                                    end
                                    if !person['<http://xmlns.com/foaf/0.1/member_name>'].nil? and person['<http://xmlns.com/foaf/0.1/member_name>'].size > 0
                                        names << person['<http://xmlns.com/foaf/0.1/member_name>'][0]
                                    end
                                end
                            end
                        end
                    end
                end
                nicks = nicks.map { |nick| nick.gsub(/(^"|"$)/,"") }
                names = names.map { |name| name.gsub(/(^"|"$)/,"") }
                results = []
                results += self.send("find_all_by_#{self.im_options[:nickname_field]}", nicks)
                results = results.select { |x| names.include?(x.name) }.uniq

                urls = nicks.map { |nick| "http://" + nick + ".livejournal.com/" }
                results += Openid.find_all_by_url(urls).map { |openid| openid.traveller }
                return results.uniq
            end

            def authsub_get(token,url,keyfile)
                uri = URI.parse(url)

                authsub = 'AuthSub'
                authsub += ' token="' + token + '"'
                if keyfile && !keyfile.blank?
                    nonce = OpenSSL::Random.random_bytes(8).unpack("I")[0].to_s
                    data = "GET #{url} #{Time.now.to_i} #{nonce}"
                    pk = OpenSSL::PKey::RSA.new(File.read(keyfile))
                    sig = pk.sign(OpenSSL::Digest::SHA1.new, data)
                    sig = Base64.encode64(sig).gsub(/\n/,"")
                    authsub += ' sigalg="rsa-sha1"'
                    authsub += ' data="' + data + '"'
                    authsub += ' sig="' + sig + '"'
                end

                uri = URI.parse(url)
                req = Net::HTTP.new(uri.host, uri.port)
                if uri.scheme == 'https'
                    req.use_ssl=true
                end
                res = req.start { |http|
                    path = uri.path
                    if uri.query
                        path += "?" + uri.query
                    end
                    http.request_get(path, { "Authorization" => authsub })
                }
                return res
            end

            def upgrade_gmail_token(token, keyfile="#{RAILS_ROOT}/db/dopplr_google.key")
                token_result = self.authsub_get(token,"https://www.google.com/accounts/AuthSubSessionToken",keyfile)
                if token_result.body.match(/^Token=(.*)$/)
                    return $1
                else
                    return nil
                end
            end

            def match_windowslive(token, initfile="#{RAILS_ROOT}/db/windowslive.xml")
                def to_signed(n)
                    length = 64

                    mid = 2**(length-1)
                    max_unsigned = 2**length
                    return (n>=mid) ? n - max_unsigned : n
                end

                require 'hpricot'
                require 'windowslivelogin'
                wll = WindowsLiveLogin.initFromXml(initfile)

                consent = wll.processConsentToken(token)
                email = []
                if !consent.nil?
                    lid = to_signed(consent.locationid.to_i(16))

                    url = "https://livecontacts.services.live.com/users/@C@#{lid}/REST/LiveContacts/Contacts"
                    auth = 'DelegatedToken dt="' + CGI.unescape(consent.delegationtoken) + '"'
                    uri = URI.parse(url)
                    req = Net::HTTP.new(uri.host, uri.port)
                    req.use_ssl = true
                    res = req.start { |http|
                        http.request_get(uri.path, { "Authorization" => auth })
                    }
                    xml = res.body
                    contacts = []
                    Hpricot.parse(xml).search("//contact").each { |e| 
                        firstname = e.search("profiles/personal/firstname/text()")
                        if firstname.nil?
                            firstname = ""
                        end
                        lastname = e.search("profiles/personal/lastname/text()")
                        if lastname.nil?
                            lastname = ""
                        end
                        name = "#{firstname} #{lastname}".strip
                        e.search("emails/email/address/text()").each { |email|
                            contacts << {
                                :name => name,
                                :email => email.to_s
                            }
                        }
                    }
                end
                users = self.send("find_all_by_#{self.im_options[:email_field]}", contacts.map { |c| c[:email] }).uniq
                emails = users.map(&:email).uniq
                names = users.map(&:name).uniq
                unused = []
                contacts.each do |contact|
                    if !emails.include?(contact[:email]) and !names.include?(contact[:name])
                        unused << contact
                    end
                end
                return [users, unused]
            end

            # Use the plugin at http://chuddup.com/blog/archive/27/drop-in-yahoo-browser-
            # to create a yahoo config file and obtain wssid and auth_cookie credentials
            # for this method
            def match_yahoo(wssid,auth_cookie)
                require 'json'

                contacts = []

                url = "http://address.yahooapis.com/v1/searchContacts?format=json&WSSID=#{wssid}&appid=#{Yahoo.config['application_id']}"
                uri = URI.parse(url)
                req = Net::HTTP.new(uri.host, uri.port)
                if uri.scheme == 'https'
                    req.use_ssl=true
                end
                res = req.start { |http|
                    path = uri.path
                    if uri.query
                        path += "?" + uri.query
                    end
                    http.request_get(path, { "Cookie" => auth_cookie })
                }
                data = JSON.parse(res.body)

                data['contacts'].each { |contact|
                    found = {}
                    fields = contact['fields']
                    fields.select { |field| field['type'] == 'email' }.each { |field| found['address'] = field['data'] }
                    fields.select { |field| field['type'] == 'name' }.each { |field| found['name'] = "#{field['first']} #{field['last']}".strip }
                    if found.has_key?('address')
                        contacts << found
                    end
                }

                users = self.send("find_all_by_#{self.im_options[:email_field]}", contacts.map { |contact| contact["address"] }).uniq
                emails = users.map(&:email)
                names = users.map(&:name)
                unused_contacts = contacts.select { |contact| 
                    !emails.include?(contact["email"]) && !names.include?(contact["name"])
                }
                return [users, unused_contacts.map { |contact| { :name => contact["name"], :email => contact["address"] } }]
            end

            def match_gmail_api(token, since=nil, keyfile="#{RAILS_ROOT}/db/dopplr_google.key")
                require 'open-uri'
                require 'openssl'
                require 'base64'
                begin
                    require 'hpricot'
                rescue MissingSourceFile
                    puts "Please install Hpricot"
                    return []
                end

                pagesize = 500
                base_url = "http://www.google.com/m8/feeds/contacts/default/base?max-results=#{pagesize}"
                if since and since.respond_to?("strftime")
                    time = since.strftime("%Y-%m-%dT%H:%M:%S.000Z")
                    base_url += "&updated-min=#{time}"
                end
                more_results = true
                contacts = []
                index = 1
                while more_results
                    url = base_url + "&start-index=#{index}"
                    res = self.authsub_get(token, url, keyfile)

                    # debugging capture
                    # open("/tmp/#{token}_#{index}.xml","w").write(res.body)
                    h = Hpricot.XML(res.body)
                    h.search("//entry").each { |em| 
                        if em.at("gd:email")
                            contacts << { 'name' => em.at("title/text()") }.merge(em.at("gd:email").attributes )
                        end
                    }
                    total = h.at("openSearch:totalResults/text()").to_s.to_i
                    start = h.at("openSearch:startIndex/text()").to_s.to_i
                    if start + pagesize < total
                        index += pagesize
                    else
                        more_results = false
                    end
                end

                users = self.send("find_all_by_#{self.im_options[:email_field]}", contacts.map { |contact| contact["address"] }).uniq
                emails = users.map(&:email)
                names = users.map(&:name)
                unused_contacts = contacts.select { |contact| 
                    !emails.include?(contact["email"]) && !names.include?(contact["name"])
                }
                return [users, unused_contacts.map { |contact| { :name => contact["name"], :email => contact["address"] } }]
            end

            def match_gmail(username,password)
                begin
                    require 'gmailer'
                rescue MissingSourceFile
                    puts "Please install gmailer"
                    return []
                end
                gmail = GMailer.connect(username, password)
                contacts = gmail.fetch(:contact => "all")
                users = self.send("find_all_by_#{self.im_options[:email_field]}", contacts.map(&:email)).uniq
                emails = users.map(&:email)
                names = users.map(&:name)
                unused_contacts = contacts.select { |contact| 
                    !emails.include?(contact.email) && !names.include?(contact.name) 
                }
                return [users, unused_contacts.map { |contact| { :name => contact.name, :email => contact.email } }]
                #return users
            end

            def match_google_socialgraph(url)
                data = google_socialgraph_query(url)
                twitternicks = []
                emails = []
                urls = []
                possible_urls = []
                data['nodes'].each_pair do |u, data|
                    possible_urls += data['nodes_referenced'].keys
                    possible_urls += data['nodes_referenced_by'].keys
                end

                possible_urls.uniq.each do |url|
                    if url.starts_with?("sgn:")
                        kind, ident = parse_socialgraph_url(url)
                        if !kind.nil?
                            case kind
                            when 'twitter'
                                twitternicks << ident
                            end
                        end
                    else
                        urls << url
                    end
                end

                users = []
                users += Openid.find_all_by_url(urls).map { |openid| openid.traveller }
                users += Openid.find_all_by_url(urls.map { |url| url + "/" }).map { |openid| openid.traveller }
                users += self.find_all_by_twitternick(twitternicks.uniq)
                users += self.send("find_all_by_#{self.im_options[:email_field]}", emails)
                return [users.uniq, []]
            end

            def parse_socialgraph_url(url)
                require 'uri'
                uri = URI.parse(url)
                kind = nil
                ident = nil
                if uri.scheme == 'sgn'
                    if uri.host.downcase.match(/([a-z0-9]+)\.com/)
                        kind = $1
                    end
                    if uri.query.downcase.match(/ident=(.+)/)
                        ident = $1
                    end
                end
                return [kind, ident]
            end

            def google_socialgraph_query(url)
                require 'json'
                require 'open-uri'
                url = "http://socialgraph.apis.google.com/lookup?q=" + CGI.escape(url) + "&fme=1&edo=1&edi=1&pretty=1&sgn=1"
                return JSON.parse(open(url).read)
            end

            def match_hcard(url=nil,uploaded=nil)
                begin
                    require 'mofo'
                rescue MissingSourceFile
                    puts "Please install mofo"
                    return nil
                end
                if !uploaded.nil?
                    hcards = HCard.find :text => uploaded.read
                end
                if !url.nil?
                    hcards = HCard.find url
                end
                if !hcards.is_a? Array
                    hcards = [hcards]
                end
                emails = hcards.select { |hcard|
                    hcard.properties.include? "email"
                }.map { |hcard|
                        hcard.email
                }.flatten

                sha1sums = hcards.select { |hcard|
                    hcard.properties.include? "foaf_mbox_sha1sum"
                }.map { |hcard|
                        hcard.foaf_mbox_sha1sum
                }.flatten

                urls = hcards.select { |hcard|
                    hcard.properties.include? "url"
                }.map { |hcard|
                        hcard.url
                }.flatten

                results = self.send("find_all_by_#{self.im_options[:email_field]}", emails)
                if sha1sums.size > 0
                    results += self.find(:all, :conditions => [ 'sha1(concat("mailto:", email)) IN (?)', sha1sums ] )
                end

                begin
                    results += Openid.find_all_by_url(urls).map { |openid| openid.traveller }
                    results += Openid.find_all_by_url(urls.map { |url| url + "/" }).map { |openid| openid.traveller }
                rescue
                    # this won't work outside Dopplr, so fail silently for others who use this plugin
                end
                return [results,[]]
            end

            def match_twitter(twittername)
                begin
                    require 'mofo'
                rescue MissingSourceFile
                    puts "Please install mofo"
                    return nil
                end
                hcards = HCard.find "http://twitter.com/" + twittername

                if !hcards.is_a? Array
                    hcards = [hcards]
                end
                nicks = hcards.select { |hcard|
                    !hcard.url.nil? and hcard.url.starts_with?("http://twitter.com/")
                }.map { |hcard|
                    hcard.url.slice(19,1000)
                }
                names = hcards.select { |hcard|
                    !hcard.url.nil? and hcard.url.starts_with?("http://twitter.com/")
                }.map { |hcard|
                    hcard.fn
                }
                results = []
                results += self.send("find_all_by_#{self.im_options[:nickname_field]}", nicks)
                results = results.select { |x| names.include?(x.name) }.uniq
                return [results, []]
            end
    
        end
        

        # Istance methods
        module InstanceMethods 
            # doing this our target class
            # acquire all the methods inside ClassMethods module
            # as class methods.

            def self.included(aClass)
                aClass.extend ClassMethods
            end 

            module ClassMethods
                # Class methods  
                # Our random function.
            end 

        end 
    end
end 
