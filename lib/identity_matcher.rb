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
                results += self.find_all_by_nick(nicks)
                results = results.select { |x| names.include?(x.name) }.uniq

                urls = nicks.map { |nick| "http://" + nick + ".livejournal.com/" }
                results += Openid.find_all_by_url(urls).map { |openid| openid.traveller }
                return results.uniq
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
                users = self.find_all_by_email(contacts.map(&:email)).uniq
                emails = users.map(&:email)
                names = users.map(&:name)
                unused_contacts = contacts.select { |contact| 
                    !emails.include?(contact.email) && !names.include?(contact.name) 
                }
                return [users, unused_contacts.map { |contact| { :name => contact.name, :email => contact.email } }]
                #return users
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
                urls = hcards.select { |hcard|
                    hcard.properties.include? "url"
                }.map { |hcard|
                        hcard.url
                }.flatten

                results = self.find_all_by_email(emails)
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
                results += self.find_all_by_nick(nicks)
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
