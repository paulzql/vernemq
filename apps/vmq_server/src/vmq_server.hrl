-include_lib("vmq_commons/include/vmq_types.hrl").
-type plugin_id()       :: {plugin, atom(), pid()}.

-type sg_policy() :: prefer_local | local_only | random.
-record(vmq_msg, {
          msg_ref               :: msg_ref() | 'undefined', % OTP-12719
          routing_key           :: routing_key() | 'undefined',
          payload               :: payload() | 'undefined',
          retain=false          :: flag(),
          dup=false             :: flag(),
          qos                   :: qos(),
          mountpoint            :: mountpoint(),
          persisted=false       :: flag(),
          sg_policy=prefer_local:: sg_policy()
         }).
-type msg()             :: #vmq_msg{}.
