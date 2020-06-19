begin;

create table iam_scope_type_enm (
  string text not null primary key check(string in ('unknown', 'organization', 'project'))
);

insert into iam_scope_type_enm (string)
values
  ('unknown'),
  ('organization'),
  ('project');

 
create table iam_scope (
    public_id wt_public_id primary key,
    create_time wt_timestamp,
    update_time wt_timestamp,
    name text,
    type text not null references iam_scope_type_enm(string) check(
      (
        type = 'organization'
        and parent_id = null
      )
      or (
        type = 'project'
        and parent_id is not null
      )
    ),
    description text,
    parent_id text references iam_scope(public_id) on delete cascade on update cascade
  );

create table iam_scope_organization (
    scope_id wt_public_id not null unique references iam_scope(public_id) on delete cascade on update cascade,
    name text unique,
    primary key(scope_id)
  );

create table iam_scope_project (
    scope_id wt_public_id not null references iam_scope(public_id) on delete cascade on update cascade,
    parent_id wt_public_id not null references iam_scope_organization(scope_id) on delete cascade on update cascade,
    name text,
    unique(parent_id, name),
    primary key(scope_id, parent_id)
  );

create or replace function 
  iam_sub_scopes_func() 
  returns trigger
as $$ 
declare parent_type int;
begin 
  if new.type = 'organization' then
    insert into iam_scope_organization (scope_id, name)
    values
      (new.public_id, new.name);
    return new;
  end if;
  if new.type = 'project' then
    insert into iam_scope_project (scope_id, parent_id, name)
    values
      (new.public_id, new.parent_id, new.name);
    return new;
  end if;
  raise exception 'unknown scope type';
end;
$$ language plpgsql;


create trigger 
  iam_scope_insert
after
insert on iam_scope 
  for each row execute procedure iam_sub_scopes_func();


create or replace function 
  iam_immutable_scope_type_func() 
  returns trigger
as $$ 
declare parent_type int;
begin 
  if new.type != old.type then
    raise exception 'scope type cannot be updated';
  end if;
  return new;
end;
$$ language plpgsql;

create trigger 
  iam_scope_update
before 
update on iam_scope 
  for each row execute procedure iam_immutable_scope_type_func();

create trigger 
  update_time_column 
before update on iam_scope 
  for each row execute procedure update_time_column();

create trigger 
  immutable_create_time
before
update on iam_scope 
  for each row execute procedure immutable_create_time_func();
  
create trigger 
  default_create_time_column
before
insert on iam_scope
  for each row execute procedure default_create_time();


-- iam_sub_names will allow us to enforce the different name constraints for
-- organizations and projects via a before update trigger on the iam_scope
-- table. 
create or replace function 
  iam_sub_names() 
  returns trigger
as $$ 
begin 
  if new.name != old.name then
    if new.type = 'organization' then
      update iam_scope_organization set name = new.name where scope_id = old.public_id;
      return new;
    end if;
    if new.type = 'project' then
      update iam_scope_project set name = new.name where scope_id = old.public_id;
      return new;
    end if;
    raise exception 'unknown scope type';
  end if;
  return new;
end;
$$ language plpgsql;

create trigger 
  iam_sub_names 
before 
update on iam_scope
  for each row execute procedure iam_sub_names();


create table iam_user (
    public_id wt_public_id not null primary key,
    create_time wt_timestamp,
    update_time wt_timestamp,
    name text,
    description text,
    scope_id wt_public_id not null references iam_scope_organization(scope_id) on delete cascade on update cascade,
    unique(name, scope_id),
    disabled boolean not null default false
  );

create trigger 
  update_time_column 
before update on iam_user 
  for each row execute procedure update_time_column();

create trigger 
  immutable_create_time
before
update on iam_user 
  for each row execute procedure immutable_create_time_func();
  
create trigger 
  default_create_time_column
before
insert on iam_user
  for each row execute procedure default_create_time();

create table iam_role (
    public_id wt_public_id not null primary key,
    create_time wt_timestamp,
    update_time wt_timestamp,
    name text,
    description text,
    scope_id wt_public_id not null references iam_scope(public_id) on delete cascade on update cascade,
    unique(name, scope_id),
    disabled boolean not null default false,
    -- version allows optimistic locking of the role when modifying the role
    -- itself and when modifying dependent items like principal roles. 
    -- TODO (jlambert 6/2020) add before update trigger to automatically
    -- increment the version when needed.  This trigger can be addded when PR
    -- #126 is merged and update_version_column() is available.
    version bigint not null default 1
  );

-- create trigger 
--   update_version_column
-- before update on iam_role
--   for each row execute procedure update_version_column();

create trigger 
  update_time_column 
before update on iam_role
  for each row execute procedure update_time_column();

create trigger 
  immutable_create_time
before
update on iam_role
  for each row execute procedure immutable_create_time_func();
  
create trigger 
  default_create_time_column
before
insert on iam_role
  for each row execute procedure default_create_time();

create table iam_group (
    public_id wt_public_id not null primary key,
    create_time wt_timestamp,
    update_time wt_timestamp,
    name text,
    description text,
    scope_id wt_public_id not null references iam_scope(public_id) on delete cascade on update cascade,
    unique(name, scope_id),
    disabled boolean not null default false
  );
  
create trigger 
  update_time_column 
before update on iam_group
  for each row execute procedure update_time_column();

create trigger 
  immutable_create_time
before
update on iam_group
  for each row execute procedure immutable_create_time_func();
  
create trigger 
  default_create_time_column
before
insert on iam_group
  for each row execute procedure default_create_time();
  
-- iam_user_role contains roles that have been assigned to users. Users can only
-- be assigned roles which are within its organization, or the role is within a project within its
-- organization. There's no way to declare this constraint, so it will be
-- maintained with a before insert trigger using iam_user_role_scope_check().
-- The rows in this table must be immutable after insert, which will be ensured
-- with a before update trigger using iam_immutable_role(). 
create table iam_user_role (
    create_time wt_timestamp,
    role_id wt_public_id not null references iam_role(public_id) on delete cascade on update cascade,
    principal_id wt_public_id not null references iam_user(public_id) on delete cascade on update cascade,
    primary key (role_id, principal_id)
  );

-- iam_group_role contains roles that have been assigned to groups. Groups can
-- only beassigned roles which are within its scope (organization or project).
-- There's no way to declare this constraint, so it will be maintained with a
-- before insert trigger using iam_group_role_scope_check(). 
-- The rows in this table must be immutable after insert, which will be ensured
-- with a before update trigger using iam_immutable_role().
create table iam_group_role (
    create_time wt_timestamp,
    role_id wt_public_id not null references iam_role(public_id) on delete cascade on update cascade,
    principal_id wt_public_id not null references iam_group(public_id) on delete cascade on update cascade,
    primary key (role_id, principal_id)
  );

-- iam_principle_role provides a consolidated view all principal roles assigned
-- (user and group roles).
create view iam_principal_role as
select
  -- intentionally using * to specify the view which requires that the concrete role assignment tables match
  *, 'user' as type
from iam_user_role
union
select
  -- intentionally using * to specify the view which requires that the concrete role assignment tables match
  *, 'group' as type
from iam_group_role;

-- iam_user_role_scope_check() ensures that the user is only assigned roles
-- which are within its organization, or the role is within a project within its
-- organization. 
create or replace function 
  iam_user_role_scope_check() 
  returns trigger
as $$ 
declare cnt int;
begin
  select count(*) into cnt
  from iam_user 
  where public_id = new.principal_id and 
  scope_id in(
    -- check to see if they have the same org scope
    select s.public_id 
      from iam_scope s, iam_role r 
      where s.public_id = r.scope_id and r.public_id = new.role_id  
    union
    -- check to see if the role has a parent that's the same org
    select s.parent_id as public_id 
      from iam_role r, iam_scope s 
      where r.scope_id = s.public_id and r.public_id = new.role_id
  );
  if cnt = 0 then
    raise exception 'user and role do not belong to the same organization';
  end if;
  return new;
end;
$$ language plpgsql;

-- iam_group_role_scope_check() ensures that the group is only assigned roles
-- which are within its scope (organization or project).
create or replace function 
  iam_group_role_scope_check() 
  returns trigger
as $$ 
declare cnt int;
begin
  select count(*) into cnt
    from iam_role r, iam_group g
    where r.scope_id = g.scope_id and g.public_id = new.principal_id and r.public_id = new.role_id;
  if cnt = 0 then
    raise exception 'group and role do not belong to the same scope';
  end if;
  return new;
end;
$$ language plpgsql;

-- iam_immutable_role() ensures that roles assigned to principals are immutable. 
create or replace function
  iam_immutable_role()
  returns trigger
as $$
begin
  if row(new.*) is distinct from row(old.*) then
    raise exception 'roles are immutable';
  end if;
  return new;
end;
$$ language plpgsql;

create trigger iam_user_role_scope_check
before
insert on iam_user_role
  for each row execute procedure iam_user_role_scope_check();

create trigger immutable_role
before
update on iam_user_role
  for each row execute procedure iam_immutable_role();

create trigger 
  immutable_create_time
before
update on iam_user_role
  for each row execute procedure immutable_create_time_func();
  
create trigger 
  default_create_time_column
before
insert on iam_user_role
  for each row execute procedure default_create_time();

create trigger iam_group_role_scope_check
before
insert on iam_group_role
  for each row execute procedure iam_group_role_scope_check();

create trigger immutable_role
before
update on iam_group_role
  for each row execute procedure iam_immutable_role();

create trigger 
  immutable_create_time
before
update on iam_group_role
  for each row execute procedure immutable_create_time_func();
  
create trigger 
  default_create_time_column
before
insert on iam_group_role
  for each row execute procedure default_create_time();

commit;