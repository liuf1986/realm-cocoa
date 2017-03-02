////////////////////////////////////////////////////////////////////////////
//
// Copyright 2014 Realm Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
////////////////////////////////////////////////////////////////////////////

#import "RLMObjectStore.h"

#import "RLMAccessor.hpp"
#import "RLMArray_Private.hpp"
#import "RLMListBase.h"
#import "RLMObservation.hpp"
#import "RLMObject_Private.hpp"
#import "RLMObjectSchema_Private.hpp"
#import "RLMOptionalBase.h"
#import "RLMProperty_Private.h"
#import "RLMQueryUtil.hpp"
#import "RLMRealm_Private.hpp"
#import "RLMSchema_Private.h"
#import "RLMSwiftSupport.h"
#import "RLMUtil.hpp"

#import "object_store.hpp"
#import "results.hpp"
#import "shared_realm.hpp"

#import <objc/message.h>

using namespace realm;

static void validateValueForProperty(__unsafe_unretained id const obj,
                                     __unsafe_unretained RLMProperty *const prop,
                                     RLMClassInfo const& info) {
    switch (prop.type) {
        case RLMPropertyTypeString:
        case RLMPropertyTypeBool:
        case RLMPropertyTypeDate:
        case RLMPropertyTypeInt:
        case RLMPropertyTypeFloat:
        case RLMPropertyTypeDouble:
        case RLMPropertyTypeData:
            if (!RLMIsObjectValidForProperty(obj, prop)) {
                @throw RLMException(@"Invalid value '%@' for property '%@.%@'",
                                    obj, info.rlmObjectSchema.className, prop.name);
            }
            break;
        case RLMPropertyTypeObject:
            break;
        case RLMPropertyTypeArray: {
            if (obj != nil && obj != NSNull.null) {
                if (![obj conformsToProtocol:@protocol(NSFastEnumeration)]) {
                    @throw RLMException(@"Array property value (%@) is not enumerable.", obj);
                }
            }
            break;
        }
        case RLMPropertyTypeAny:
        case RLMPropertyTypeLinkingObjects:
            @throw RLMException(@"Invalid value '%@' for property '%@.%@'",
                                obj, info.rlmObjectSchema.className, prop.name);
    }
}

RLMAccessorContext::RLMAccessorContext(RLMRealm *realm, RLMClassInfo& info, bool is_create)
: _realm(realm), _info(info), _is_create(is_create)
{
}

RLMAccessorContext::RLMAccessorContext(RLMObjectBase *parent)
: _realm(parent->_realm), _info(*parent->_info), _is_create(false), _parentObject(parent)
{
}

id RLMAccessorContext::defaultValue(NSString *key) {
    if (!_defaultValues) {
        _defaultValues = RLMDefaultValuesForObjectSchema(_info.rlmObjectSchema);
    }
    return _defaultValues[key];
}

id RLMAccessorContext::value(id obj, size_t propIndex) {
    auto prop = _info.rlmObjectSchema.properties[propIndex];
    id value = doGetValue(obj, propIndex, prop);
    if (value) {
        validateValueForProperty(value, prop, _info);
    }

    if (!_is_create && [obj isKindOfClass:_info.rlmObjectSchema.objectClass] && !prop.swiftIvar) {
        // set the ivars for object and array properties to nil as otherwise the
        // accessors retain objects that are no longer accessible via the properties
        // this is mainly an issue when the object graph being added has cycles,
        // as it's not obvious that the user has to set the *ivars* to nil to
        // avoid leaking memory
        if (prop.type == RLMPropertyTypeObject || prop.type == RLMPropertyTypeArray) {
            ((void(*)(id, SEL, id))objc_msgSend)(obj, prop.setterSel, nil);
        }
    }

    return value;
}

id RLMAccessorContext::doGetValue(id obj, size_t propIndex, __unsafe_unretained RLMProperty *const prop) {
    // Property value from an NSArray
    if ([obj respondsToSelector:@selector(objectAtIndex:)])
        return propIndex < [obj count] ? [obj objectAtIndex:propIndex] : nil;

    // Property value from an NSDictionary
    if ([obj respondsToSelector:@selector(objectForKey:)])
        return [obj objectForKey:prop.name];

    // Property value from an instance of this object type
    if ([obj isKindOfClass:_info.rlmObjectSchema.objectClass]) {
        if (prop.swiftIvar) {
            if (prop.type == RLMPropertyTypeArray) {
                return static_cast<RLMListBase *>(object_getIvar(obj, prop.swiftIvar))._rlmArray;
            }
            else { // optional
                return static_cast<RLMOptionalBase *>(object_getIvar(obj, prop.swiftIvar)).underlyingValue;
            }
        }
    }

    // Property value from some object that's KVC-compatible
    return RLMValidatedValueForProperty(obj, [obj respondsToSelector:prop.getterSel] ? prop.getterName : prop.name, _info.rlmObjectSchema.className) ?: NSNull.null;
}

size_t RLMAccessorContext::addObject(id value, std::string const& object_type, bool is_update) {
    if (auto object = RLMDynamicCast<RLMObjectBase>(value)) {
        // FIXME: is_create should be before this check, right?
        if (object->_realm == _realm && object->_info->objectSchema->name == object_type) {
            RLMVerifyAttached(object);
            return object->_row.get_index();
        }
    }

    if (_is_create) {
        return RLMCreateObjectInRealmWithValue(_realm, @(object_type.c_str()), value, is_update)->_row.get_index();
    }

    RLMAddObjectToRealm(value, _realm, is_update);
    return static_cast<RLMObjectBase *>(value)->_row.get_index();
}

id RLMAccessorContext::wrap(realm::List l) {
    REALM_ASSERT(_parentObject);
    REALM_ASSERT(currentProperty);
    return [[RLMArrayLinkView alloc] initWithList:std::move(l) realm:_realm
                                       parentInfo:_parentObject->_info
                                         property:currentProperty];
}

id RLMAccessorContext::wrap(realm::Object o) {
    return RLMCreateObjectAccessor(_realm, _info.linkTargetType(currentProperty.index), o.row().get_index());
}

id RLMAccessorContext::wrap(realm::Results r) {
    return [RLMResults resultsWithObjectInfo:_realm->_info[currentProperty.objectClassName]
                                     results:std::move(r)];
}

void RLMAccessorContext::will_change(realm::Row const& row, realm::Property const& prop) {
    _observationInfo = RLMGetObservationInfo(nullptr, row.get_index(), _info);
    if (_observationInfo) {
        _kvoPropertyName = @(prop.name.c_str());
        _observationInfo->willChange(_kvoPropertyName);
    }
}

void RLMAccessorContext::did_change() {
    if (_observationInfo) {
        _observationInfo->didChange(_kvoPropertyName);
        _kvoPropertyName = nil;
        _observationInfo = nullptr;
    }
}

id RLMAccessorContext::value_for_property(id dict, std::string const&, size_t prop_index) {
    return value(dict, prop_index);
}

bool RLMAccessorContext::dict_has_value_for_key(id dict, const std::string &prop_name) {
    if ([dict respondsToSelector:@selector(objectForKey:)]) {
        return [dict objectForKey:@(prop_name.c_str())];
    }
    return [dict valueForKey:@(prop_name.c_str())];
}

id RLMAccessorContext::dict_value_for_key(id dict, const std::string &prop_name) {
    return [dict valueForKey:@(prop_name.c_str())];
}

size_t RLMAccessorContext::list_size(id v) { return [v count]; }
id RLMAccessorContext::list_value_at_index(id v, size_t index) {
    return [v objectAtIndex:index];
}

bool RLMAccessorContext::has_default_value_for_property(Realm*, ObjectSchema const&, std::string const& prop)
{
    return defaultValue(@(prop.c_str()));
}

id RLMAccessorContext::default_value_for_property(Realm*, ObjectSchema const&,
                                     std::string const& prop)
{
    return defaultValue(@(prop.c_str()));
}

size_t RLMAccessorContext::to_object_index(SharedRealm, id value, std::string const& object_type, bool update)
{
    return addObject(value, object_type, update);
}

void RLMRealmCreateAccessors(RLMSchema *schema) {
    const size_t bufferSize = sizeof("RLM:Managed  ") // includes null terminator
                            + std::numeric_limits<unsigned long long>::digits10
                            + realm::Group::max_table_name_length;

    char className[bufferSize] = "RLM:Managed ";
    char *const start = className + strlen(className);

    for (RLMObjectSchema *objectSchema in schema.objectSchema) {
        if (objectSchema.accessorClass != objectSchema.objectClass) {
            continue;
        }

        static unsigned long long count = 0;
        sprintf(start, "%llu %s", count++, objectSchema.className.UTF8String);
        objectSchema.accessorClass = RLMManagedAccessorClassForObjectClass(objectSchema.objectClass, objectSchema, className);
    }
}

static inline void RLMVerifyRealmRead(__unsafe_unretained RLMRealm *const realm) {
    if (!realm) {
        @throw RLMException(@"Realm must not be nil");
    }
    [realm verifyThread];
}

static inline void RLMVerifyInWriteTransaction(__unsafe_unretained RLMRealm *const realm) {
    RLMVerifyRealmRead(realm);
    // if realm is not writable throw
    if (!realm.inWriteTransaction) {
        @throw RLMException(@"Can only add, remove, or create objects in a Realm in a write transaction - call beginWriteTransaction on an RLMRealm instance first.");
    }
}

void RLMInitializeSwiftAccessorGenerics(__unsafe_unretained RLMObjectBase *const object) {
    if (!object || !object->_row || !object->_objectSchema->_isSwiftClass) {
        return;
    }
    if (![object isKindOfClass:object->_objectSchema.objectClass]) {
        // It can be a different class if it's a dynamic object, and those don't
        // require any init here (and would crash since they don't have the ivars)
        return;
    }

    for (RLMProperty *prop in object->_objectSchema.swiftGenericProperties) {
        if (prop->_type == RLMPropertyTypeArray) {
            RLMArray *array = [[RLMArrayLinkView alloc] initWithParent:object property:prop];
            [object_getIvar(object, prop.swiftIvar) set_rlmArray:array];
        }
        else if (prop.type == RLMPropertyTypeLinkingObjects) {
            id linkingObjects = object_getIvar(object, prop.swiftIvar);
            [linkingObjects setObject:(id)[[RLMWeakObjectHandle alloc] initWithObject:object]];
            [linkingObjects setProperty:prop];
        }
        else {
            RLMOptionalBase *optional = object_getIvar(object, prop.swiftIvar);
            optional.property = prop;
            optional.object = object;
        }
    }
}

void RLMAddObjectToRealm(__unsafe_unretained RLMObjectBase *const object,
                         __unsafe_unretained RLMRealm *const realm,
                         bool createOrUpdate) {
    RLMVerifyInWriteTransaction(realm);

    // verify that object is unmanaged
    if (object.invalidated) {
        @throw RLMException(@"Adding a deleted or invalidated object to a Realm is not permitted");
    }
    if (object->_realm) {
        if (object->_realm == realm) {
            // Adding an object to the Realm it's already manged by is a no-op
            return;
        }
        // for differing realms users must explicitly create the object in the second realm
        @throw RLMException(@"Object is already managed by another Realm. Use create instead to copy it into this Realm.");
    }
    if (object->_observationInfo && object->_observationInfo->hasObservers()) {
        @throw RLMException(@"Cannot add an object with observers to a Realm");
    }

    auto& info = realm->_info[object->_objectSchema.className];
    RLMAccessorContext c{realm, info, false};
    object->_info = &info;
    object->_realm = realm;
    object->_objectSchema = info.rlmObjectSchema;
    try {
        realm::Object::create(c, realm->_realm, *info.objectSchema, (id)object,
                              createOrUpdate, &object->_row);
    }
    catch (std::exception const& e) {
        @throw RLMException(@"%s", e.what());
    }
    object_setClass(object, info.rlmObjectSchema.accessorClass);
    RLMInitializeSwiftAccessorGenerics(object);
}

RLMObjectBase *RLMCreateObjectInRealmWithValue(RLMRealm *realm, NSString *className,
                                               id value, bool createOrUpdate = false) {
    RLMVerifyInWriteTransaction(realm);

    if (createOrUpdate && RLMIsObjectSubclass([value class])) {
        RLMObjectBase *obj = value;
        if (obj->_realm == realm && [obj->_objectSchema.className isEqualToString:className]) {
            // This is a no-op if value is an RLMObject of the same type already backed by the target realm.
            return value;
        }
    }

    if (!value || value == NSNull.null) {
        @throw RLMException(@"Must provide a non-nil value.");
    }

    // create the object
    auto& info = realm->_info[className];
    RLMAccessorContext c{realm, info, true};
    RLMObjectBase *object = RLMCreateManagedAccessor(info.rlmObjectSchema.accessorClass, realm, &info);
    try {
        object->_row = realm::Object::create(c, realm->_realm, *info.objectSchema,
                                             (id)value, createOrUpdate).row();
    }
    catch (std::exception const& e) {
        @throw RLMException(e);
    }
    RLMInitializeSwiftAccessorGenerics(object);
    return object;
}

void RLMDeleteObjectFromRealm(__unsafe_unretained RLMObjectBase *const object,
                              __unsafe_unretained RLMRealm *const realm) {
    if (realm != object->_realm) {
        @throw RLMException(@"Can only delete an object from the Realm it belongs to.");
    }

    RLMVerifyInWriteTransaction(object->_realm);

    // move last row to row we are deleting
    if (object->_row.is_attached()) {
        RLMTrackDeletions(realm, ^{
            object->_row.get_table()->move_last_over(object->_row.get_index());
        });
    }

    // set realm to nil
    object->_realm = nil;
}

void RLMDeleteAllObjectsFromRealm(RLMRealm *realm) {
    RLMVerifyInWriteTransaction(realm);

    // clear table for each object schema
    for (auto& info : realm->_info) {
        RLMClearTable(info.second);
    }
}

RLMResults *RLMGetObjects(__unsafe_unretained RLMRealm *const realm,
                          NSString *objectClassName,
                          NSPredicate *predicate) {
    RLMVerifyRealmRead(realm);

    // create view from table and predicate
    RLMClassInfo& info = realm->_info[objectClassName];
    if (!info.table()) {
        // read-only realms may be missing tables since we can't add any
        // missing ones on init
        return [RLMResults resultsWithObjectInfo:info results:{}];
    }

    if (predicate) {
        realm::Query query = RLMPredicateToQuery(predicate, info.rlmObjectSchema, realm.schema, realm.group);
        return [RLMResults resultsWithObjectInfo:info
                                         results:realm::Results(realm->_realm, std::move(query))];
    }

    return [RLMResults resultsWithObjectInfo:info
                                     results:realm::Results(realm->_realm, *info.table())];
}

id RLMGetObject(RLMRealm *realm, NSString *objectClassName, id key) {
    RLMVerifyRealmRead(realm);

    RLMAccessorContext *c = nullptr;
    auto& info = realm->_info[objectClassName];
    try {
        auto obj = realm::Object::get_for_primary_key(*c, realm->_realm, *info.objectSchema, key ?: NSNull.null);
        if (!obj.row().is_attached())
            return nil;
        return RLMCreateObjectAccessor(realm, info, obj.row().get_index());
    }
    catch (std::exception const& e) {
        @throw RLMException(e);
    }
}

RLMObjectBase *RLMCreateObjectAccessor(__unsafe_unretained RLMRealm *const realm,
                                       RLMClassInfo& info,
                                       NSUInteger index) {
    return RLMCreateObjectAccessor(realm, info, (*info.table())[index]);
}

// Create accessor and register with realm
RLMObjectBase *RLMCreateObjectAccessor(__unsafe_unretained RLMRealm *const realm,
                                       RLMClassInfo& info,
                                       realm::RowExpr row) {
    RLMObjectBase *accessor = RLMCreateManagedAccessor(info.rlmObjectSchema.accessorClass, realm, &info);
    accessor->_row = row;
    RLMInitializeSwiftAccessorGenerics(accessor);
    return accessor;
}
