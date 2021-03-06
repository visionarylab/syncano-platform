# -*- coding: utf-8 -*-
# Generated by Django 1.9.4 on 2016-05-23 14:28
from django.db import migrations

import apps.core.fields
import apps.core.validators


class Migration(migrations.Migration):

    dependencies = [
        ('data', '0018_acl'),
    ]

    operations = [
        migrations.AddField(
            model_name='klass',
            name='objects_acl',
            field=apps.core.fields.NullableJSONField(blank=True, default=None, null=True),
        ),
        migrations.AlterField(
            model_name='klass',
            name='objects_acl',
            field=apps.core.fields.NullableJSONField(blank=True, default={'*': ['get', 'list', 'create', 'update', 'delete']}, null=True),
        ),
        migrations.AlterField(
            model_name='klass',
            name='name',
            field=apps.core.fields.StrippedSlugField(max_length=64, validators=[apps.core.validators.NotInValidator(values={'self', 'user', 'users', 'acl'})]),
        ),
    ]
