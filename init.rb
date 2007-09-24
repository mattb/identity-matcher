require 'identity_matcher'

ActiveRecord::Base.send(:include, IdentityMatcher::Methods)
