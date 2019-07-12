require "csv"
require "uuid"
require "base64"

require "./user.cr"
require "./group.cr"

# FIXME: Should we work on arrays and convert to CSV at the last second when adding rows?

class Passwd
	@passwd : String
	@group : String

	# FIXME: Missing operations:
	#   - Removing users.
	#   - Reading groups.
	#   - Adding and removing groups (ok, maybe admins can do that?)
	#   - Adding users to group.
	#   - Removing users from group.

	# FIXME: Safety. Ensure passwd and group cannot be in a half-written state. (backups will probably work well enough in the mean-time)

	def initialize(@passwd, @group)
	end

	private def passwd_as_array
		CSV.parse File.read(@passwd), separator: ':'
	end

	private def group_as_array
		CSV.parse File.read(@group), separator: ':'
	end

	private def set_user_groups(user : AuthD::User)
		group_as_array.each do |line|
			group = AuthD::Group.new line

			if group.users.any? { |name| name == user.login }
				user.groups << group.name
			end
		end
	end

	def each_user(&block)
		passwd_as_array.each do |line|
			yield AuthD::User.new line
		end
	end

	def user_exists?(login : String) : Bool
		each_user do |user|
			return true if user.login == login
		end

		false
	end

	def get_user(uid : Int32) : AuthD::User?
		each_user do |user|
			if user.uid == uid
				set_user_groups user

				return user
			end
		end
	end

	##
	# Will fail if the user is found but the password is invalid.
	def get_user(login : String, password : String) : AuthD::User?
		hash = Passwd.hash_password password

		each_user do |user|
			if user.login == login
				if user.password_hash == hash
					set_user_groups user

					return user
				end

				next
			end
		end
	end

	def get_all_users
		users = Array(AuthD::User).new

		passwd_as_array.each do |line|
			users << AuthD::User.new line
		end

		users
	end

	def get_all_groups
		groups = Array(AuthD::Group).new

		group_as_array.each do |line|
			groups << AuthD::Group.new line
		end

		groups
	end

	def to_passwd
		get_all_users.map(&.to_csv).join("\n") + "\n"
	end

	def to_group
		get_all_groups.map(&.to_csv).join("\n") + "\n"
	end

	private def get_free_uid
		uid = 1000

		users = get_all_users

		while users.any? &.uid.== uid
			uid += 1
		end

		uid
	end

	private def get_free_gid
		gid = 1000

		users = get_all_users

		while users.any? &.gid.== gid
			gid += 1
		end

		gid
	end

	def self.hash_password(password)
		digest = OpenSSL::Digest.new("sha256")
		digest << password
		digest.hexdigest
	end

	def add_user(login, password = nil, uid = nil, gid = nil, home = "/", shell = "/bin/nologin")
		# FIXME: If user already exists, exception? Replacement?

		uid = get_free_uid if uid.nil?

		gid = get_free_gid if gid.nil?

		password_hash = if password
			Passwd.hash_password password
		else
			"x"
		end

		user = AuthD::User.new login, password_hash, uid, gid, home, shell

		File.write(@passwd, user.to_csv + "\n", mode: "a")

		add_group login, gid: gid, users: [user.login]

		set_user_groups user

		user
	end

	def add_group(name, password_hash = "x", gid = nil, users = Array(String).new)
		gid = get_free_gid if gid.nil?

		group = AuthD::Group.new name, password_hash, gid, users

		File.write(@group, group.to_csv + "\n", mode: "a")
	end

	# FIXME: Edit other important fields.
	def mod_user(uid, password_hash : String? = nil, avatar : String? = nil)
		new_passwd = passwd_as_array.map do |line|
			user = AuthD::User.new line	

			if uid == user.uid
				password_hash.try do |hash|
					user.password_hash = hash
				end

				avatar.try do |avatar|
					user.avatar = avatar
				end

				user.to_csv
			else
				line.join(':')
			end
		end

		File.write @passwd, new_passwd.join("\n") + "\n"
	end
end

class AuthD::Group
	def initialize(line : Array(String))
		@name = line[0]
		@password_hash = line[1]
		@gid = line[2].to_i

		@users = line[3].split ","
	end

	def to_csv
		[@name, @password_hash, @gid, @users.join ","].join ":"
	end
end

class AuthD::User
	def initialize(line : Array(String))
		@login = line[0]
		@password_hash = line[1]

		@uid = line[2].to_i
		@gid = line[3].to_i

		CSV.parse(line[4], separator: ',')[0]?.try do |gecos|
			@full_name = gecos[0]?
			@location = gecos[1]?
			@office_phone_number = gecos[2]?
			@home_phone_number = gecos[3]?
			@other_contact = gecos[4]?

			# CAUTION: NON-STANDARD EXTENSION
			@avatar = gecos[5]?.try do |x|
				if x != ""
					Base64.decode_string x
				else
					nil
				end
			end
		end

		# FIXME: What about those two fields? Keep them, remove them?
		@home = line[5]
		@shell = line[6]
	end

	def to_csv
		[@login, @password_hash, @uid, @gid, gecos, @home, @shell].join ":"
	end

	def gecos
		unless @location || @office_phone_number || @home_phone_number || @other_contact || @avatar
			if @full_name
				return @full_name
			else
				return ""
			end
		end

		[@full_name || "", @location || "", @office_phone_number || "", @home_phone_number || "", @other_contact || "", Base64.strict_encode(@avatar || "")].join ","
	end
end

