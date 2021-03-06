#
# Author:: Ronald Doorn (<rdoorn@schubergphilis.com>)
# Cookbook Name:: firewall
# Provider:: rule_iptables
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
class Chef
  class Provider::FirewallRuleFirewalld < Provider
    include Poise
    include Chef::Mixin::ShellOut
    include FirewallCookbook::Helpers

    def action_allow
      apply_rule(:allow)
    end

    def action_deny
      apply_rule(:deny)
    end

    def action_reject
      apply_rule(:reject)
    end

    def action_redirect
      apply_rule(:redirect)
    end

    def action_masquerade
      apply_rule(:masquerade)
    end

    def action_log
      apply_rule(:log)
    end

    def action_remove
      # TODO: specify which target to delete
      # for now this will remove raw + all targeted lines
      remove_rule(:allow)
      remove_rule(:deny)
      remove_rule(:reject)
      remove_rule(:redirect)
      remove_rule(:masquerade)
    end

    private

    CHAIN = { :in => 'INPUT', :out => 'OUTPUT', :pre => 'PREROUTING', :post => 'POSTROUTING' } # , nil => "FORWARD"}
    TARGET = { :allow => 'ACCEPT', :reject => 'REJECT', :deny => 'DROP', :masquerade => 'MASQUERADE', :redirect => 'REDIRECT', :log => 'LOG --log-prefix \'iptables: \' --log-level 7' }

    def apply_rule(type = nil)
      ip_versions.each do |ip_version|
        firewall_command = 'firewall-cmd --direct --add-rule '

        # TODO: implement logging for :connections :packets
        firewall_rule = build_firewall_rule(type, ip_version)

        Chef::Log.debug("#{new_resource}: #{firewall_rule}")
        if rule_exists?(firewall_rule)
          Chef::Log.info("#{new_resource} #{type} rule exists... won't apply")
        else
          cmdstr = firewall_command + firewall_rule
          converge_by("firewall_rule[#{new_resource.name}] #{firewall_rule}") do
            notifying_block do
              shell_out!(cmdstr) # shell_out! is already logged
              new_resource.updated_by_last_action(true)
            end
          end
        end
      end
    end

    def remove_rule(type = nil)
      ip_versions.each do |ip_version|
        firewall_command = 'firewall-cmd --direct --remove-rule '

        # TODO: implement logging for :connections :packets
        firewall_rule = build_firewall_rule(type)

        Chef::Log.debug("#{new_resource}: #{firewall_rule}")
        if rule_exists?(firewall_rule)
          cmdstr = firewall_command + firewall_rule
          converge_by("firewall_rule[#{new_resource.name}] #{firewall_rule}") do
            notifying_block do
              shell_out!(cmdstr) # shell_out! is already logged
              new_resource.updated_by_last_action(true)
            end
          end
        else
          Chef::Log.info("#{new_resource} #{type} rule does not exists... won't remove")
        end
      end
    end

    def is_ipv4_rule?
      if ((new_resource.source && IPAddr.new(new_resource.source).ipv4?) ||
          (new_resource.destination && IPAddr.new(new_resource.destination).ipv4?))
        true
      else
        false
      end
    end

    def is_ipv6_rule?
      if ((new_resource.source && IPAddr.new(new_resource.source).ipv6?) ||
          (new_resource.destination && IPAddr.new(new_resource.destination).ipv6?))
        true
      else
        false
      end
    end

    def ip_versions
      if is_ipv4_rule?
        versions = ['ipv4']
      elsif is_ipv6_rule?
        versions = ['ipv6']
      else # no source or destination address, add rules for both ipv4 and ipv6
        versions = ['ipv4','ipv6']
      end
      versions
    end

    def build_firewall_rule(type = nil, ip_version = 'ipv4')
      if new_resource.raw
        firewall_rule = new_resource.raw.strip
      else
        firewall_rule = "#{ip_version} filter "
        if new_resource.direction
          firewall_rule << "#{CHAIN[new_resource.direction.to_sym]} "
        else
          firewall_rule << 'FORWARD '
        end
        firewall_rule << "#{new_resource.position ? new_resource.position : 1} "

        if [:pre, :post].include?(new_resource.direction)
          firewall_rule << '-t nat '
        end

        # Firewalld order of prameters is important here see example output below:
        # ipv4 filter INPUT 1 -s 1.2.3.4/32 -d 5.6.7.8/32 -i lo -p tcp -m tcp -m state --state NEW -m comment --comment "hello" -j DROP
        firewall_rule << "-s #{new_resource.source} " if new_resource.source && new_resource.source != '0.0.0.0/0'
        firewall_rule << "-d #{new_resource.destination} " if new_resource.destination

        firewall_rule << "-i #{new_resource.interface} " if new_resource.interface
        firewall_rule << "-o #{new_resource.dest_interface} " if new_resource.dest_interface

        firewall_rule << "-p #{new_resource.protocol} " if new_resource.protocol
        firewall_rule << '-m tcp ' if new_resource.protocol.to_sym == :tcp

        # using multiport here allows us to simplify our greps and rule building
        firewall_rule << "-m multiport --sports #{port_to_s(new_resource.source_port)} " if new_resource.source_port
        firewall_rule << "-m multiport --dports #{port_to_s(dport_calc)} " if dport_calc

        firewall_rule << "-m state --state #{new_resource.stateful.is_a?(Array) ? new_resource.stateful.join(',').upcase : new_resource.stateful.upcase} " if new_resource.stateful
        firewall_rule << "-m comment --comment '#{new_resource.description}' "
        firewall_rule << "-j #{TARGET[type]} "
        firewall_rule << "--to-ports #{new_resource.redirect_port} " if type == 'redirect'
        firewall_rule.strip!
      end
      firewall_rule
    end

    def rule_exists?(rule)
      fail 'no rule supplied' unless rule

      # match quotes generously
      detect_rule = rule.gsub(/'/, "'*")

      match = shell_out!('firewall-cmd --direct --get-all-rules').stdout.lines.find do |line|
        # Chef::Log.debug("matching: [#{detect_rule}] to [#{line.chomp.rstrip}]")
        line =~ /#{detect_rule}/
      end

      match
    rescue Mixlib::ShellOut::ShellCommandFailed
      Chef::Log.debug("#{new_resource} check fails with: " + match.inspect)
      Chef::Log.debug("#{new_resource} assuming #{rule} rule does not exist")
      false
    end

    def dport_calc
      new_resource.dest_port || new_resource.port
    end
  end
end
